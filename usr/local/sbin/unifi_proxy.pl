#!/usr/bin/perl

### echo 1 > /proc/sys/net/ipv4/tcp_tw_recycle 
#    Enable fast recycling TIME-WAIT sockets. Default value is 0.
#    It should not be changed without advice/request of technical
#    experts.

use strict;
use warnings;
use Data::Dumper;
use JSON::XS ();
use LWP ();
use POSIX;
use POSIX ":sys_wait_h";
use IO::Socket;
use IO::Handle;
use Symbol;
use IO::Socket::SSL ();
use PerlIO;

use constant {
     ACT_COUNT => 'count',
     ACT_SUM => 'sum',
     ACT_GET => 'get',
     ACT_DISCOVERY => 'discovery',
     BY_CMD => 1,
     BY_GET => 2,
     CONFIG_FILE_DEFAULT => '/etc/unifi_proxy/unifi_proxy.conf',
     CONTROLLER_VERSION_2 => 'v2',
     CONTROLLER_VERSION_3 => 'v3',
     CONTROLLER_VERSION_4 => 'v4',
     DEBUG_LOW => 1,
     DEBUG_MID => 2,
     DEBUG_HIGH => 3,
     KEY_ITEMS_NUM => 'items_num',
     MSG_UNKNOWN_CONTROLLER_VERSION => 'Version of controller is unknown: ',
     OBJ_USW => 'usw',
     OBJ_USW_PORT => 'usw_port',
     OBJ_UPH => 'uph',
     OBJ_UAP => 'uap',
     OBJ_USG => 'usg',
     OBJ_WLAN => 'wlan',
     OBJ_USER => 'user',
     OBJ_SITE => 'site',
     OBJ_HEALTH => 'health',
#     OBJ_SYSINFO => 'sysinfo',
     TOOL_NAME => 'UniFi Proxy',
     TOOL_VERSION => '1.0.0',
     TOOL_HOMEPAGE => 'https://github.com/zbx-sadman/unifi_proxy',
     SERVER_DEFAULT_IP => '127.0.0.1',
     SERVER_DEFAULT_PORT => 7777,
     SERVER_DEFAULT_MAXCLIENTS => 10,
     SERVER_DEFAULT_STARTSERVERS => 3,
     SERVER_DEFAULT_MAXREQUESTSPERCHILD => 1024,
     TRUE => 1,
     FALSE => 0,

};

IO::Socket::SSL::set_default_context(new IO::Socket::SSL::SSL_Context(SSL_version => 'tlsv1', SSL_verify_mode => 0));

sub addToLLD;
sub fetchData;
sub fetchDataFromController;
sub getMetric;
sub handleCHLDSignal;
sub handleConnection;
sub handleTERMSignal;
sub makeLLD;
sub readConf;

my $options, my $ck, my $wk, my $res;
foreach my $arg (@ARGV) {
  # try to take key from arg[i]
  ($ck) =  $arg =~ m/^-(.+)/;
  # key is '--version' ? Set flag && do nothing inside loop
  $options->{'version'} = TRUE, next if ($ck && ($ck eq '-version'));
  # key is --help - do the same
  $options->{'help'} = TRUE, next if ($ck && ($ck eq '-help'));
  # key is defined? Init hash item
  $options->{$ck}='' if ($ck);
  # not defined - store value to hash item with 'key' id.
  $options->{$wk}=$arg, next unless ($ck);
  # remember key for next loop, where it may be used for storing value to hash
  $wk=$ck;
}
            

if ($options->{'version'}) {
   print "\n",TOOL_NAME," v", TOOL_VERSION ,"\n";
   exit 0;
}
  
if ($options->{'help'}) {
   print "\n",TOOL_NAME," v", TOOL_VERSION, "\n\nusage: $0 [-C /path/to/config/file] [-D]",
          "\n\t-C\tpath to config file\n\t-D\trun in daemon mode\n\nAll other help on ", TOOL_HOMEPAGE, "\n\n";
   exit 0;
}

# take config filename from -"C"onfig option or from `default` const 
my $configFile=(defined ($options->{'C'})) ? $options->{'C'} : CONFIG_FILE_DEFAULT;

# in not defined -"F"oregroundMode option - going to daemon mode
#unless (defined ($options->{'F'})) {
if (defined ($options->{'D'})) {
   my $pid = fork();
   exit() if $pid;
   die "Couldn't fork: $! " unless defined($pid);
   # Link session to term
   POSIX::setsid() || die "[!] Can't start a new session ($!)";
}

my $globalConfig   = {}; 
# PreForked servers PID store
my $servers        = {};
# PreForked servers number
my $servers_num    = 0;

# Read config
readConf;

# Bind to addr:port
my $server = IO::Socket::INET->new(LocalAddr => $globalConfig->{'listenip'}, 
                                   LocalPort => $globalConfig->{'listenport'}, 
                                   Listen    => $globalConfig->{'maxclients'},
                                   Reuse     => 1,
                                   Type      => SOCK_STREAM,
                                   Proto     => 'tcp',) || die $@; 



# Start new servers 
for (1 .. $globalConfig->{'startservers'}) {
    makeServer();
}

# Assign subs to handle Signals
$SIG{INT}= \&handleINTSignal;
$SIG{HUP} = \&handleHUPSignal;
$SIG{CHLD} = \&handleCHLDSignal;
#$SIG{TERM}
# And maintain the population.

while (1) {
    # wait for a signal (i.e., child's death)
    sleep;                          
    for (my $i = $servers_num; $i < $globalConfig->{'startservers'}; $i++) {
        # add several server instances if need
        makeServer();             
    }
}


############################################################################################################################
#
#                                                      Subroutines
#
############################################################################################################################
sub logMessage
  {
    return unless ($globalConfig->{'debuglevel'} >= $_[1]);
    print "[$$] ", time, " $_[0]\n";
  }
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Handle CHLD signal
#    - Wait to terminate child process (kill zombie)
#    - Close listen port
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub handleCHLDSignal {
    $SIG{CHLD} = \&handleCHLDSignal;
    my $pid = wait;
#    print "\n [CHLD] reaper for $pid";
    $servers_num --;
    delete $servers->{$pid};
}

sub handleHUPSignal {
#    print "\n [HUP] kill servers", print Dumper keys $servers;
#    local($SIG{CHLD}) = 'IGNORE';   # we're going to kill our children
#    kill 'INT' => keys $servers;
#    print "\n ReadConf";
    readConf;
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Handle TERM signal
#    - Set global flag, which using for main loop exiting
#    - Close listen port
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub handleINTSignal {
    local($SIG{CHLD}) = 'IGNORE';   # we're going to kill our children
#    print "\n [INT] kill servers", print Dumper $servers;
    kill 'INT' => keys $servers;
    exit;                           # clean up with dignity
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Make new server with PreFork engine
#    - Fork new server process
#    - Accept and handle connection from IO::SOCket queue
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub makeServer {
    my $pid;
    my $sigset;
    # make copy of global config to stop change $_[0] by fork's copy-write procedure
#    my $gC;
   
    # why `my` do not copy $globalConfig to $gC?
#    while(my ($k,$v) = each $globalConfig) { $gC->{$k}= $v; };
    # block signal for fork
    $sigset = POSIX::SigSet->new(SIGINT);
    sigprocmask(SIG_BLOCK, $sigset) or die "[!] Can't block SIGINT for fork: $!\n";

    # if $pid is undefined - fork creating error caused
    die "[!] fork: $!" unless defined ($pid = fork);
    
    if ($pid) {
        # Parent records the child's birth and returns.
        sigprocmask(SIG_UNBLOCK, $sigset) or die "[!] Can't unblock SIGINT for fork: $!\n";
        $servers->{$pid} = 1;
        $servers_num++;
        $globalConfig->{'pid'}=$pid;
        return;
    } else {
        #############################################    
        # Child can *not* return from this subroutine.
        #############################################    
        # make SIGINT kill us as it did before
        $SIG{INT} = 'DEFAULT';     

        # unblock signals
        sigprocmask(SIG_UNBLOCK, $sigset) or die "[!] Can't unblock SIGINT for fork: $!\n";

        my $serverConfig;
        # copy hash with globalConfig to serverConfig to prevent 'copy-on-write'.
        %{$serverConfig}=%{$globalConfig;};

        # init service keys
        # Level of dive (recursive call) for getMetric subroutine
        $serverConfig->{'dive_level'} = 1;
        # Max level to which getMetric is dived
        $serverConfig->{'max_depth'} = 0;
        # Data is downloaded instead readed from file
        $serverConfig->{'downloaded'} = FALSE;
        # LWP::UserAgent object, which must be saved between fetchData() calls
        $serverConfig->{'ua'} = undef;
        # JSON::XS object
        $serverConfig->{'jsonxs'} = JSON::XS->new->utf8;
        # Already logged sign
        $serverConfig->{'logged_in'} = FALSE;
        # -s option used sign
        $globalConfig->{'sitename_given'} = FALSE;

        # handle connections until we've reached MaxRequestsPerChild
        for (my $i=0; $i < $serverConfig->{'maxrequestsperchild'}; $i++) {
            my $client = $server->accept() or last;
            $client->autoflush(1);
            handleConnection($serverConfig, $client);
        }
        # tidy up gracefully and finish
    
        # this exit is VERY important, otherwise the child will become
        # a producer of more and more children, forking yourself into
        # process death.
        exit;
    }
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Handle incoming connection
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub handleConnection {
    my $socket = $_[1];
    my $res;
    my @objJSON=();
    my $gC;

    # copy serverConfig to localConfig for saving default values 
    %{$gC}=%{$_[0]};

    # read line from socket
    while (my $line=<$socket>) {
       chomp ($line);
       next unless ($line);
       $res=undef,
       $gC->{'action'} = '', $gC->{'objecttype'} = '', $gC->{'cachemaxage'} = '', $gC->{'key'} = '', $gC->{'sitename'} = '',  $gC->{'sitename_given'}= FALSE;
       logMessage("[.]\t\tIncoming line: '$line'", DEBUG_LOW);
       # split line to action, object type, sitename, key, id, cache_timeout (need to add user name, user password, controller version ?)
       my ($opt_a, $opt_o, $opt_s, $opt_k, $opt_i, $opt_c)=split(",",$line);

       # Rewrite default values (taken from globalConfig) by command line arguments
       $gC->{'action'}       = $opt_a ? $opt_a : $_[0]->{'action'};
       $gC->{'objecttype'}   = $opt_o ? $opt_o : $_[0]->{'objecttype'};
       $gC->{'key'}          = $opt_k ? $opt_k : $_[0]->{'key'};

       # if opt_c given, but = 0 - "$opt_k ?" is false and $gC->{'cachemaxage'} take default value;
       $gC->{'cachemaxage'}  = defined($opt_c) ? $opt_c : $_[0]->{'cachemaxage'};

       # opt_s not '' (virtual -s option used) -> use given sitename. Otherwise use 'default'
       if ($opt_s) {
           $gC->{'sitename_given'} = TRUE,
           $gC->{'sitename'}       = $opt_s;
       } else {
           $gC->{'sitename_given'} = FALSE,
           $gC->{'sitename'}     = $_[0]->{'default_sitename'};
       }

       # test for $opt_i is MAC or ID
       if ($opt_i) {
          $_=uc($opt_i);
          if ( /^([0-9A-Z]{2}[:-]){5}([0-9A-Z]{2})$/ ) {
             # is MAC
             $gC->{'mac'} = $opt_i;
          } else {
             # is ID
             $gC->{'id'} = $opt_i;
          }
       }

       # flag for LLD routine
      if ($gC->{'action'} eq ACT_DISCOVERY) {
          # Call sub for made LLD-like JSON
          logMessage("[*] LLD", DEBUG_LOW);
          makeLLD($gC, $res);
       } else { 
         if ($gC->{'key'}) {
             # Key is given - need to get metric. 
             # if $globalConfig->{'id'} is exist then metric of this object has returned. 
             # If not - calculate $globalConfig->{'action'} for all items in objects list (all object of type = 'object name', for example - all 'uap'
             # load JSON data & get metric
             logMessage("[*] Key given: $gC->{'key'}", DEBUG_LOW);
             getMetric($gC, \@objJSON, $gC->{'key'}, $res) if (fetchData($gC, $gC->{'sitename'}, $gC->{'objecttype'}, \@objJSON));
         }
       }

       # Value could be 'null'. If need to replace null to other char - {'null_char'} must be defined
       $res = $res ? $res : $gC->{'null_char'} if (defined($gC->{'null_char'}));
       # Push result of work to stdout
       print $socket (defined($res) ? "$res\n" : "\n");
       @objJSON=();
  }

      # Logout need if logging in before (in fetchData() sub) completed
      logMessage("[*] Logout from UniFi controller", DEBUG_LOW), $gC->{'ua'}->get($gC->{'logout_path'}) if ($gC->{'logged_in'});
      return TRUE;
}
    
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Recursively go through the key and take/form value of metric
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub getMetric {
    # $_[0] - GlobalConfig
    # $_[1] - array/hash with info
    # $_[2] - key
    # $_[3] - result

    # dive to...
    $_[0]->{'dive_level'}++;

    logMessage("[+] ($_[0]->{'dive_level'}) getMetric() started", DEBUG_LOW);
    my $key=$_[2];

    logMessage("[>]\t args: key: '$_[2]', action: '$_[0]->{'action'}'", DEBUG_LOW);
#    logMessage("[>]\t incoming object info:'\n\t".(Dumper $_[1]), DEBUG_HIGH);

    # correcting maxDepth for ACT_COUNT operation
    $_[0]->{'max_depth'} = ($_[0]->{'dive_level'} > $_[0]->{'max_depth'}) ? $_[0]->{'dive_level'} : $_[0]->{'max_depth'};
    
    # Checking for type of $_[1]. 
    # if $_[1] is array - need to explore any element
    if (ref($_[1]) eq 'ARRAY') {
       my $paramValue, my $objList=@{$_[1]};
       logMessage("[.]\t\t Array with $objList objects detected", DEBUG_MID);

       # if metric ask "how much items (AP's for example) in all" - just return array size (previously calculated in $objList) and do nothing more
       if ($key eq KEY_ITEMS_NUM) { 
          $_[3]=$objList; 
       } else {
          $_[3]=0; 
          logMessage("[.]\t\t Taking value from all sections", DEBUG_MID);
          # Take each element of array
          for (my $i=0; $i < $objList; $i++ ) {
            # Init $paramValue for right actions doing
            $paramValue=undef;
            # Do recursively calling getMetric func for each element 
            # that is bad strategy, because sub calling anytime without tesing of key existiense, but that testing can be slower, that sub recalling 
            #                                                                                                                    (if filter-key used)
            getMetric($_[0], $_[1][$i], $key, $paramValue); 
            logMessage("[.]\t\t paramValue: '$paramValue'", DEBUG_HIGH) if (defined($paramValue));


            # Otherwise - do something line sum or count
            if (defined($paramValue)) {
               logMessage("[.]\t\t act #$_[0]->{'action'}", DEBUG_MID);

               # With 'get' action jump out from loop with first recieved value
               $_[3]=$paramValue, last if ($_[0]->{'action'} eq ACT_GET);

               # !!! need to fix trying sum of not numeric values
               # With 'sum' - grow $result
               if ($_[0]->{'action'} eq ACT_SUM) { 
                  $_[3]+=$paramValue; 
               } elsif ($_[0]->{'action'} eq ACT_COUNT) {
                  # may be wrong algo :(
                  # workaround for correct counting with deep diving
                  # With 'count' we must count keys in objects, that placed only on last level
                  # in other case $result will be incremented by $paramValue (which is number of key in objects inside last level table)
                  if (($_[0]->{'max_depth'}-$_[0]->{'dive_level'}) < 2 ) {
                     $_[3]++; 
                  } else {
                     $_[3]+=$paramValue; 
                  }
              }
            }
            logMessage("[.]\t\t Value: '$paramValue', result: '$_[3]'", DEBUG_MID) if (defined($paramValue));
          } #foreach 
       }
   } else { # if (ref($_[1]) eq 'ARRAY') {
      # it is not array (list of objects) - it's one object (hash)
      logMessage("[.]\t\t Just one object detected", DEBUG_MID);
      my $tableName, my @fData=(), my $matchCount=0;
      ($tableName, $key) = split(/[.]/, $key, 2);

      # if key is not defined after split (no comma in key) that mean no table name exist in incoming key 
      # and key is first and only one part of splitted data
      if (! defined($key)) { 
         $key = $tableName; undef $tableName;
      } else {
         my $fKey, my $fValue, my $fStr;
         # check for [filterkey=value&filterkey=value&...] construction in tableName. If that exist - key filter feature will enabled
         #($fStr) = $tableName =~ m/^\[([\w]+=.+&{0,1})+\]/;
         # regexp matched string placed into $1 and $1 listed as $fStr
         ($fStr) = $tableName =~ m/^\[(.+)\]/;

         if ($fStr) {
            # filterString is exist - need to split its to key=value pairs with '&' separator
            my @fStrings = split('&', $fStr);

            # After splitting split again - for get keys and values. And store it.
            for (my $i=0; $i < @fStrings; $i++) {
                # Split pair with '=' separator
                ($fKey, $fValue) = split('=', $fStrings[$i]);
                # If key/value splitting was correct - store filter data into list of hashes
                push(@fData, {key=>$fKey, val=> $fValue}) if (defined($fKey) && defined($fValue));
             }
             # Flush tableName's value if tableName is represent filter-key
             undef $tableName;
          }
       } # if (! defined($key)) ... else ... 

       # Test current object with filter-keys 
       if (@fData) {
          logMessage("\t\t Matching object's keys...", DEBUG_MID);
          # run trought flter list
          for (my $i=0; $i < @fData; $i++ ) {
             # if key (from filter) in object is defined and its value equal to value of filter - increase counter
             $matchCount++ if (defined($_[1]->{$fData[$i]->{'key'}}) && ($_[1]->{$fData[$i]->{'key'}} eq $fData[$i]->{val}))
          }     
        }

       # Subtable could be not exist as 'vap_table' for UAPs which is powered off.
       # In this case $result must stay undefined for properly processed on previous dive level if subroutine is called recursively
       # Pass inside if no filter defined (@fData == $matchCount == 0) or all keys is matched
       if ($matchCount == @fData) {
          logMessage("[.]\t\t Object is good", DEBUG_MID);
          if ($tableName && defined($_[1]->{$tableName})) {
             # if subkey was detected (tablename is given an exist) - do recursively calling getMetric func with subtable and subkey and get value from it
             logMessage("[.]\t\t It's object. Go inside", DEBUG_MID);
             getMetric($_[0], $_[1]->{$tableName}, $key, $_[3]); 
          } elsif (defined($_[1]->{$key})) {
             # Otherwise - just return value for given key
             logMessage("[.]\t\t It's key. Take value... '$_[1]->{$key}'", DEBUG_MID);
             $_[3]=$_[1]->{$key};
          } else {
             logMessage("[.]\t\t No key or table exist :(", DEBUG_MID);
          }
       } # if ($matchCount == @fData)
   } # if (ref($_[1]) eq 'ARRAY') ... else ...

  logMessage("[<] ($_[0]->{'dive_level'}) getMetric() finished /$_[0]->{'max_depth'}/", DEBUG_LOW);
  logMessage("[<] result: ($_[3])", DEBUG_LOW) if (defined($_[3]));

  #float up...
  $_[0]->{'dive_level'}--;
  return TRUE;
}


#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Fetch data from cache or call fetching from controller. Renew cache files.
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub fetchData {
   # $_[0] - $GlobalConfig
   # $_[1] - sitename
   # $_[2] - object type
   # $_[3] - jsonData object ref
   logMessage("[+] fetchData() started", DEBUG_LOW);
   logMessage("[>]\t args: object type: '$_[0]->{'objecttype'}'", DEBUG_MID);
   logMessage("[>]\t id: '$_[0]->{'id'}'", DEBUG_MID) if ($_[0]->{'id'});
   logMessage("[>]\t mac: '$_[0]->{'mac'}'", DEBUG_MID) if ($_[0]->{'mac'});
   my $cacheExpire=TRUE, my $needReadCache=TRUE, my $fh, my $jsonData, my $cacheFileName, my $tmpCacheFileName,  my $objPath;

   $objPath  = $_[0]->{'api_path'} . ($_[0]->{'fetch_rules'}->{$_[2]}->{'excl_sitename'} ? '' : "/s/$_[1]") . "/$_[0]->{'fetch_rules'}->{$_[2]}->{'path'}";
   # if MAC is given with command-line option -  RapidWay for Controller v4 is allowed
   $objPath.="/$_[0]->{'mac'}" if (($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_4) && $_[0]->{'mac'});
   logMessage("[.]\t\t Object path: '$objPath'", DEBUG_MID);

   ################################################## Take JSON  ##################################################

   # If CacheMaxAge = 0 - do not try to read/update cache - fetch data from controller
   if (0 == $_[0]->{'cachemaxage'}) {
      logMessage("[.]\t\t No read/update cache because CacheMaxAge = 0", DEBUG_MID);
      fetchDataFromController($_[0], $objPath, $jsonData);
   } else {
      # Change all [:/.] to _ to make correct filename
      ($cacheFileName = $objPath) =~ tr/\/\:\./_/, 
      $cacheFileName = $_[0]->{'cacheroot'} .'/'. $cacheFileName;
      # Cache filename point to dir? If so - die to avoid problem with read or link/unlink operations
#      (-d $cacheFileName) || logMessage("[!] Can't handle '$tmpCacheFileName' through its dir, stop.", DEBUG_LOW), return FALSE;
      logMessage("[.]\t\t Cache file name: '$cacheFileName'", DEBUG_MID);
      # Cache file is exist and non-zero size? // need -e $cacheFileName or not?
      if (-s $cacheFileName) { 
         # Yes, it is non-zero -> exist.
         # Check cache age
         my @fileStat = stat($cacheFileName);
         $cacheExpire = FALSE if (($fileStat[9] + $_[0]->{'cachemaxage'}) > time());
         # Cache file is not exist => cache is expire => need to create
      }

      if ($cacheExpire) {
         # Cache expire - need to update
         logMessage("[.]\t\t Cache expire or not found. Renew...", DEBUG_MID);
         $tmpCacheFileName = $cacheFileName . ".tmp";
         # Temporary cache filename point to dir? If so - die to avoid problem with write or link/unlink operations
         logMessage("[!] Can't handle '$tmpCacheFileName' through its dir, stop.", DEBUG_LOW), return FALSE if (-d $tmpCacheFileName);
         logMessage("[.]\t\t Temporary cache file='$tmpCacheFileName'", DEBUG_MID);
         if (open ($fh, ">", $tmpCacheFileName)) {
               # try to lock temporary cache file and no wait for locking.
               # LOCK_EX | LOCK_NB
            if (flock ($fh, 2 | 4)) {
               # if Miner could lock temporary file, it...
               chmod (0666, $fh);
               # ...fetch new data from controller...
               fetchDataFromController($_[0], $objPath, $jsonData);
               # unbuffered write it to temp file..
               syswrite ($fh, $_[0]->{'jsonxs'}->encode($jsonData));
               # Now unlink old cache filedata from cache filename 
               # All processes, who already read data - do not stop and successfully completed reading
               unlink ($cacheFileName);
               # Link name of cache file to temp file. File will be have two link - to cache and to temporary cache filenames. 
               # New run down processes can get access to data by cache filename
               link($tmpCacheFileName, $cacheFileName) or logMessage("[!] Presumably no rights to unlink '$cacheFileName' file ($!). Try to delete it ", DEBUG_LOW), return FALSE;
               # Unlink temp filename from file. 
               # Process, that open temporary cache file can do something with filedata while file not closed
               unlink($tmpCacheFileName) or logMessage("[!] '$tmpCacheFileName' unlink error ($!), stop", DEBUG_LOW), return FALSE;
               # Close temporary file. close() unlock filehandle.
               close($fh) or logMessage("[!] Can't close locked temporary cache file '$tmpCacheFileName' ($!), stop", DEBUG_LOW), return FALSE; 
               # No cache read from file need
               $needReadCache=FALSE;
            } else {
               close ($fh) or logMessage("[!] Can't close temporary cache file '$tmpCacheFileName' ($!), stop", DEBUG_LOW), return FALSE;
            }
        }
      } # if ($cacheExpire)

      # if need load data from cache file
      if ($needReadCache) {
       # open file
       open($fh, "<:mmap", $cacheFileName) or logMessage("[!] Can't open '$cacheFileName' ($!), stop.", DEBUG_LOW), return FALSE;
       # read data from file
#       $jsonData=JSON::XS::decode_json(<$fh>);
       $jsonData=$_[0]->{'jsonxs'}->decode(<$fh>);
       # close cache
       close($fh) or logMessage( "[!] Can't close cache file ($!), stop.", DEBUG_LOW), return FALSE;
    }
  } # if (0 == $_[0]->{'cachemaxage'})

  ################################################## JSON processing ##################################################
  # Take each object
  for (my $i=0; $i < @{$jsonData}; $i++) {
     # Test object's type or pass if 'obj-have-no-type' (workaround for WLAN, for example)
     my $objType=@{$jsonData}[$i]->{'type'};
     next if (defined($objType) && ($objType ne $_[2]));
     # ID is given by command-line?
     # No ID given. Push all object which have correct type and skip next steps
     push (@{$_[3]}, @{$jsonData}[$i]), next unless ($_[0]->{'id'});

     # These steps is executed if ID is given

     # Taking from json-key object's ID
     # UBNT Phones store ID into 'device_id' key (?)
     my $objID = ($_[2] eq OBJ_UPH) ? @{$jsonData}[$i]->{'device_id'} : @{$jsonData}[$i]->{'_id'}; 

     # It is required object?
     # Yes. Push object to global @objJSON and jump out from the loop
     push (@{$_[3]}, @{$jsonData}[$i]), last if ($objID eq $_[0]->{'id'});
   } # foreach jsonData

#   logMessage("[<]\t Fetched data:\n\t".(Dumper $_[3]), DEBUG_HIGH);
   logMessage("[-] fetchData() finished", DEBUG_LOW);
   return TRUE;
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Fetch data from from controller.
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub fetchDataFromController {
   # $_[0] - GlobalConfig
   # $_[1] - object path
   # $_[2] - jsonData object ref
   my $response, my $fetchType=$_[0]->{'fetch_rules'}->{$_[0]->{'objecttype'}}->{'method'}, 
   my $fetchCmd=$_[0]->{'fetch_rules'}->{$_[0]->{'objecttype'}}->{'cmd'};

   logMessage("[+] fetchDataFromController() started", DEBUG_LOW);
   logMessage("[>]\t args: object path: '$_[1]'", DEBUG_LOW);

   # HTTP UserAgent init
   # Set SSL_verify_mode=off to login without certificate manipulation
   $_[0]->{'ua'} = LWP::UserAgent-> new(cookie_jar => {}, agent => TOOL_NAME."/".TOOL_VERSION." (perl engine)",
                                        ssl_opts => {SSL_verify_mode => 0, verify_hostname => 0}) unless ($_[0]->{'ua'});

   ################################################## Logging in  ##################################################
   # how to check 'still logged' state?
   unless ($_[0]->{'logged_in'}) {
     logMessage("[.]\t\t Try to log in into controller...", DEBUG_LOW);
     $response=$_[0]->{'ua'}->post($_[0]->{'login_path'}, 'Content_type' => "application/$_[0]->{'login_type'}", 'Content' => $_[0]->{'login_data'});
#     logMessage("[>>]\t\t HTTP respose:\n\t".(Dumper $response), DEBUG_HIGH);
     my $rc=$response->code;
     if ($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_4) {
        # v4 return 'Bad request' (code 400) on wrong auth
        die "\n[!] Login error: code $rc, stop." if ($rc eq '400');
        # v4 return 'OK' (code 200) on success login and must die only if get error
        die "\n[!] Other HTTP error: $rc, stop." if ($response->is_error);
     } elsif (($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_3) || ($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_2)) {
        # v3 return 'OK' (code 200) on wrong auth
        die "\n[!] Login error: $rc, stop." if ($response->is_success );
        # v3 return 'Redirect' (code 302) on success login and must die only if code<>302
        die "\n[!] Other HTTP error: $rc, stop." if ($rc ne '302');
#     } else {
#        # v2 code
#        ;
       }
     logMessage("Login successfully", DEBUG_LOW);
     $_[0]->{'logged_in'} = TRUE; 
  }


   ################################################## Fetch data from controller  ##################################################

   if (BY_CMD == $fetchType) {
      logMessage("[.]\t\t Fetch data with CMD method: '$fetchCmd'", DEBUG_MID);
      $response=$_[0]->{'ua'}->post($_[1], 'Content_type' => 'application/json', 'Content' => $fetchCmd);

   } elsif (BY_GET == $fetchType) {
      logMessage("[.]\t\t Fetch data with GET method from: '$_[1]'", DEBUG_MID);
      $response=$_[0]->{'ua'}->get($_[1]);
   }

   die "\n[!] JSON taking error, HTTP code: ", $response->status_line unless ($response->is_success), ", stop.";
#   logMessage("[>>]\t Fetched data:\n\t".(Dumper $response->decoded_content), DEBUG_HIGH);
   $_[2]=$_[0]->{'jsonxs'}->decode($response->decoded_content);
   my $jsonMeta=$_[2]->{'meta'}->{'rc'};
   # server answer is ok ?
   die "[!] getJSON error: rc=$jsonMeta, stop." if ($jsonMeta ne 'ok'); 
   $_[2]=$_[2]->{'data'};
#   logMessage("[<]\t decoded data:\n\t".(Dumper $_[2]), DEBUG_HIGH);

   logMessage("[-] fetchDataFromController() finished", DEBUG_LOW);
   $_[0]->{'downloaded'}=TRUE;
   return TRUE;
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Generate LLD-like JSON using fetched data
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub makeLLD {
    # $_[0] - $globalConfig
    # $_[1] - result

    logMessage("[+] makeLLD() started", DEBUG_LOW);
    logMessage("[>]\t args: object type: '$_[0]->{'objecttype'}'", DEBUG_MID);
    my $jsonObj, my $lldResponse, my $lldPiece, my $siteList=(), my $objList, 
    my $givenObjType=$_[0]->{'objecttype'}, my $siteWalking=TRUE;

    $siteWalking=FALSE if (($givenObjType eq OBJ_USW_PORT) && ($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_4) || ($_[0]->{'unifiversion'} eq CONTROLLER_VERSION_3));

    if (! $siteWalking) {
       # 'no sites walking' routine code here
       logMessage("[.]\t\t 'No sites walking' routine activated", DEBUG_MID);

       # Take objects
       # USW Ports LLD workaround: Store USW with given ID to $objList and then rewrite $objList with subtable {'port_table'}. 
       # Then make LLD for USW_PORT object
       if ($givenObjType eq OBJ_USW_PORT) {
          fetchData($_[0], $_[0]->{'sitename'}, OBJ_USW, $objList);# or return FALSE;
          $objList= $objList ? @{$objList}[0]->{'port_table'} : ();
       } else {
          fetchData($_[0], $_[0]->{'sitename'}, $givenObjType, $objList);# or return FALSE;
       }

#       logMessage("[.]\t\t Objects list:\n\t".(Dumper $objList), DEBUG_HIGH);
       # Add info to LLD-response 
       addToLLD($_[0], undef, $objList, $lldPiece) if ($objList);
    } else {
       # Get site list
       fetchData($_[0], $_[0]->{'sitename'}, OBJ_SITE, $siteList);# or return FALSE;
#       logMessage("\n[.]\t\t Sites list:\n\t".(Dumper $siteList), DEBUG_MID);
       # User ask LLD for 'site' object - make LLD piece with site list.
       if ($givenObjType eq OBJ_SITE) {
          addToLLD($_[0], undef, $siteList, $lldPiece) if ($siteList);
       } else {
       # User want to get LLD with objects for all or one sites
          foreach my $siteObj (@{$siteList}) {
             # skip hidden site 'super', 0+ convert literal true/false to decimal
             next if (exists($siteObj->{'attr_hidden'}) && (0+$siteObj->{'attr_hidden'}));
             # skip site, if '-s' option used and current site other, that given
             next if ($_[0]->{'sitename_given'} && ($_[0]->{'sitename'} ne $siteObj->{'name'}));
             logMessage("[.]\t\t Handle site: '$siteObj->{'name'}'", DEBUG_MID);
             # Not nulled list causes duplicate LLD items
             $objList=();
             # Take objects from foreach'ed site
             fetchData($_[0], $siteObj->{'name'}, $givenObjType, $objList);# or return FALSE;
             # Add its info to LLD-response 
#             logMessage("[.]\t\t Objects list:\n\t".(Dumper $objList), DEBUG_MID);
             addToLLD($_[0], $siteObj, $objList, $lldPiece) if ($objList);
          } 
       } 
    } 
    
    # link LLD to {'data'} key
    $_[1]->{'data'} = $lldPiece;
    # make JSON
    $_[1]=$_[0]->{'jsonxs'}->encode($_[1]);
#    logMessage("[<]\t Generated LLD:\n\t".(Dumper $_[1]), DEBUG_HIGH);
    logMessage("[-] makeLLD() finished", DEBUG_LOW);
    return TRUE;
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Add a piece to exists LLD-like JSON 
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub addToLLD {
    # $_[0] - $globalConfig
    # $_[1] - Site object
    # $_[2] - Incoming objects list
    # $_[3] - Outgoing objects list
    my $givenObjType=$_[0]->{'objecttype'};
    logMessage("[+] addToLLD() started", DEBUG_LOW);
    logMessage("[>]\t args: object type: '$_[0]->{'objecttype'}'", DEBUG_MID);
    logMessage("[>]\t       site name: '$_[1]->{'name'}'", DEBUG_MID) if ($_[1]->{'name'});;

    # $i - incoming object's array element pointer. 
    # $o - outgoing object's array element pointer, init as length of that array to append elements to the end
    my $o = defined($_[3]) ? @{$_[3]} : 0;
    for (my $i=0; $i < @{$_[2]}; $i++, $o++) {
      $_[3][$o]->{'{#NAME}'}     = $_[2][$i]->{'name'} if ($_[2][$i]->{'name'});
      $_[3][$o]->{'{#ID}'}       = $_[2][$i]->{'_id'} if ($_[2][$i]->{'_id'});
      # $_[1] is undefined if script uses with v2 controller or generate LLD for OBJ_SITE  
      # ...but undef transform to {} - why? Test length of hash...
      $_[3][$o]->{'{#SITENAME}'} = $_[1]->{'name'} if (%{$_[1]});
      $_[3][$o]->{'{#SITEID}'}   = $_[1]->{'_id'} if (%{$_[1]});
      $_[3][$o]->{'{#IP}'}       = $_[2][$i]->{'ip'}  if ($_[2][$i]->{'ip'});
      $_[3][$o]->{'{#MAC}'}      = $_[2][$i]->{'mac'} if ($_[2][$i]->{'mac'});
      # state of object: 0 - off, 1 - on
      $_[3][$o]->{'{#STATE}'}    = "$_[2][$i]->{'state'}" if ($_[2][$i]->{'state'});

      if ($givenObjType eq OBJ_HEALTH) {
         $_[3][$o]->{'{#SUBSYSTEM}'}= $_[2][$i]->{'subsystem'};
      } elsif ($givenObjType eq OBJ_WLAN) {
         # is_guest key could be not exist with 'user' network on v3 
         $_[3][$o]->{'{#ISGUEST}'}= "$_[2][$i]->{'is_guest'}" if (exists($_[2][$i]->{'is_guest'}));
      } elsif ($givenObjType eq OBJ_USER ) {
         $_[3][$o]->{'{#NAME}'}   = $_[2][$i]->{'hostname'};
         # sometime {hostname} may be null. UniFi controller replace that hostnames by {'mac'}
         $_[3][$o]->{'{#NAME}'}   = $_[2][$i]->{'hostname'} ? $_[2][$i]->{'hostname'} : $_[3][$o]->{'{#MAC}'};
      } elsif ($givenObjType eq OBJ_UPH ) {
         $_[3][$o]->{'{#ID}'}     = $_[2][$i]->{'device_id'};
      } elsif ($givenObjType eq OBJ_SITE) {
         # 0+ - convert 'true'/'false' to 1/0 
         next if (exists($_[2][$i]->{'attr_hidden'}) && (0+$_[2][$i]->{'attr_hidden'}));
         $_[3][$o]->{'{#DESC}'}     = $_[2][$i]->{'desc'};
      } elsif ($givenObjType eq OBJ_USW_PORT) {
         $_[3][$o]->{'{#PORTIDX}'}     = "$_[2][$i]->{'port_idx'}";
         $_[3][$o]->{'{#MEDIA}'}     = $_[2][$i]->{'media'};
         $_[3][$o]->{'{#UP}'}     = "$_[2][$i]->{'up'}";
#      } elsif ($givenObjType eq OBJ_UAP) {
#         ;
#      } elsif ($givenObjType eq OBJ_USG || $givenObjType eq OBJ_USW) {
#        ;
      }
    }

#    logMessage("[<]\t Generated LLD piece:\n\t".(Dumper $_[3]), DEBUG_HIGH);
    logMessage("\n[-] addToLLD() finished", DEBUG_LOW);
    return TRUE;
}

#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
#
#  Read config file
#    - Read param values from file
#    - If they valid - store its into #globalConfig
#
#  ! all incoming variables is global
#
#*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/*/
sub readConf {
    $globalConfig=undef;
    open(my $fh, $configFile) || die "\nCan't open config file: '$configFile'";
    # Read default values for global scope from config file
    while(my $line=<$fh>){
         $line =~ /^($|#)/ && next;
         chomp($line);
         # 'key =    value' => 'key' & 'value'
         my ($key, $val)= $line =~ m/\s*(\w+)\s*=\s*(\S*)\s*/;
         $globalConfig->{lc($key)} = $val;
    }
    close($fh);

   $globalConfig->{'listenip'}             = SERVER_DEFAULT_IP unless (defined($globalConfig->{'listenip'}));
   $globalConfig->{'listenport'}           = SERVER_DEFAULT_PORT unless (defined($globalConfig->{'listenport'}));
   $globalConfig->{'maxclients'}           = SERVER_DEFAULT_MAXCLIENTS unless (defined($globalConfig->{'connlimit'}));
   $globalConfig->{'startservers'}         = SERVER_DEFAULT_STARTSERVERS unless (defined($globalConfig->{'startservers'}));
   $globalConfig->{'maxrequestsperchild'}  = SERVER_DEFAULT_MAXREQUESTSPERCHILD unless (defined($globalConfig->{'startservers'}));

   $globalConfig->{'action'}  	    = ACT_DISCOVERY unless (defined($globalConfig->{'action'}));
   $globalConfig->{'objecttype'}    = OBJ_WLAN unless (defined($globalConfig->{'objecttype'}));

   $globalConfig->{'cacheroot'}     = '/dev/shm' unless (defined($globalConfig->{'cacheroot'}));
   $globalConfig->{'cachemaxage'}   = 60 unless (defined($globalConfig->{'cachemaxage'}));
   $globalConfig->{'unifilocation'} = '127.0.0.1:8443' unless (defined($globalConfig->{'unifilocation'}));
   $globalConfig->{'unifiversion'}  = CONTROLLER_VERSION_4 unless (defined($globalConfig->{'unifiversion'}));
   $globalConfig->{'unifiuser'}     = 'admin' unless (defined($globalConfig->{'unifiuser'}));
   $globalConfig->{'unifipass'}     = 'ubnt' unless (defined($globalConfig->{'unifipass'}));
   $globalConfig->{'debuglevel'}    = FALSE unless (defined($globalConfig->{'debuglevel'}));
   $globalConfig->{'sitename'}      = 'default' unless (defined($globalConfig->{'sitename'}));

   # cast literal to digital
   $globalConfig->{'cachemaxage'} += 0, $globalConfig->{'debuglevel'} += 0; $globalConfig->{'listenport'} +=0;
   $globalConfig->{'startservers'} += 0, $globalConfig->{'maxrequestsperchild'} += 0; 

   # Sitename which replaced {'sitename'} if '-s' option not used
   $globalConfig->{'default_sitename'} = 'default';

    $globalConfig->{'api_path'}      = "$globalConfig->{'unifilocation'}/api";
    $globalConfig->{'login_path'}    = "$globalConfig->{'unifilocation'}/api/login";
    $globalConfig->{'logout_path'}   = "$globalConfig->{'unifilocation'}/logout";
    $globalConfig->{'login_data'}    = "username=$globalConfig->{'unifiuser'}&password=$globalConfig->{'unifipass'}&login=login";
    $globalConfig->{'login_type'}    = 'x-www-form-urlencoded';

    # Set controller version specific data
    if ($globalConfig->{'unifiversion'} eq CONTROLLER_VERSION_4) {
       $globalConfig->{'login_data'} = "{\"username\":\"$globalConfig->{'unifiuser'}\",\"password\":\"$globalConfig->{'unifipass'}\"}",
       $globalConfig->{'login_type'} = 'json',
       # Data fetch rules.
       # BY_GET mean that data fetched by HTTP GET from .../api/[s/<site>/]{'path'} operation.
       #    [s/<site>/] must be excluded from path if {'excl_sitename'} is defined
       # BY_CMD say that data fetched by HTTP POST {'cmd'} to .../api/[s/<site>/]{'path'}
       #
       $globalConfig->{'fetch_rules'} = {
       # `&` let use value of constant, otherwise we have 'OBJ_UAP' => {...} instead 'uap' => {...}
       #     &OBJ_HEALTH => {'method' => BY_GET, 'path' => 'stat/health'},
          &OBJ_SITE     => {'method' => BY_GET, 'path' => 'self/sites', 'excl_sitename' => TRUE},
          &OBJ_UAP      => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_UPH      => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_USG      => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_USW      => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_USW_PORT => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_USER     => {'method' => BY_GET, 'path' => 'stat/sta'},
          &OBJ_WLAN     => {'method' => BY_GET, 'path' => 'list/wlanconf'}
       };
    } elsif ($globalConfig->{'unifiversion'} eq CONTROLLER_VERSION_3) {
       $globalConfig->{'fetch_rules'} = {
          # `&` let use value of constant, otherwise we have 'OBJ_UAP' => {...} instead 'uap' => {...}
          &OBJ_SITE => {'method' => BY_CMD, 'path' => 'cmd/sitemgr', 'cmd' => '{"cmd":"get-sites"}'},
          #&OBJ_SYSINFO => {'method' => BY_GET, 'path' => 'stat/sysinfo'},
          &OBJ_UAP  => {'method' => BY_GET, 'path' => 'stat/device'},
          &OBJ_USER => {'method' => BY_GET, 'path' => 'stat/sta'},
          &OBJ_WLAN => {'method' => BY_GET, 'path' => 'list/wlanconf'}
       };
    } elsif ($globalConfig->{'unifiversion'} eq CONTROLLER_VERSION_2) {
       $globalConfig->{'fetch_rules'} = {
       # `&` let use value of constant, otherwise we have 'OBJ_UAP' => {...} instead 'uap' => {...}
          &OBJ_UAP  => {'method' => BY_GET, 'path' => 'stat/device', 'excl_sitename' => TRUE},
          &OBJ_WLAN => {'method' => BY_GET, 'path' => 'list/wlanconf', 'excl_sitename' => TRUE},
          &OBJ_USER => {'method' => BY_GET, 'path' => 'stat/sta', 'excl_sitename' => TRUE}
       };
    } else {
       return "[!]", MSG_UNKNOWN_CONTROLLER_VERSION, ": '$globalConfig->{'unifiversion'},'";
    }

   return TRUE;
}
