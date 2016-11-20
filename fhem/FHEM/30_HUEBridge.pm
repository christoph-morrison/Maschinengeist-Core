
# $Id$

# "Hue Personal Wireless Lighting" is a trademark owned by Koninklijke Philips Electronics N.V.,
# see www.meethue.com for more information.
# I am in no way affiliated with the Philips organization.

package main;

use strict;
use warnings;
use POSIX;
use JSON;
use Data::Dumper;

use HttpUtils;

my $HUEBridge_isFritzBox = undef;
sub
HUEBridge_isFritzBox()
{
  $HUEBridge_isFritzBox = int( qx( [ -f /usr/bin/ctlmgr_ctl ] && echo 1 || echo 0 ) )  if( !defined( $HUEBridge_isFritzBox) );

  return $HUEBridge_isFritzBox;
}

sub HUEBridge_Initialize($)
{
  my ($hash) = @_;

  # Provider
  $hash->{ReadFn}  = "HUEBridge_Read";
  $hash->{WriteFn} = "HUEBridge_Read";
  $hash->{Clients} = ":HUEDevice:";

  #Consumer
  $hash->{DefFn}    = "HUEBridge_Define";
  $hash->{NotifyFn} = "HUEBridge_Notify";
  $hash->{SetFn}    = "HUEBridge_Set";
  $hash->{GetFn}    = "HUEBridge_Get";
  $hash->{AttrFn}   = "HUEBridge_Attr";
  $hash->{UndefFn}  = "HUEBridge_Undefine";
  $hash->{AttrList} = "key disable:1 disabledForIntervals httpUtils:1,0 noshutdown:1,0 pollDevices:1,0 queryAfterSet:1,0 $readingFnAttributes";
}

sub
HUEBridge_Read($@)
{
  my ($hash,$chash,$name,$id,$obj)= @_;

  return HUEBridge_Call($hash, $chash, 'groups/' . $1, $obj)  if( $id =~ m/^G(\d.*)/ );

  return HUEBridge_Call($hash, $chash, 'sensors/' . $1, $obj) if( $id =~ m/^S(\d.*)/ );

  return HUEBridge_Call($hash, $chash, 'lights/' . $id, $obj);
}

sub
HUEBridge_Detect($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  Log3 $name, 3, "HUEBridge_Detect";

  my ($err,$ret) = HttpUtils_BlockingGet({
    url => "http://www.meethue.com/api/nupnp",
    method => "GET",
  });

  if( defined($err) && $err ) {
    Log3 $name, 3, "HUEBridge_Detect: error detecting bridge: ".$err;
    return;
  }

  my $host = '';
  if( defined($ret) && $ret ne '' && $ret =~ m/^[\[{].*[\]}]$/ ) {
    my $obj = eval { from_json($ret) };
    Log3 $name, 2, "$name: json error: $@ in $ret" if( $@ );

    if( defined($obj->[0])
        && defined($obj->[0]->{'internalipaddress'}) ) {
      $host = $obj->[0]->{'internalipaddress'};
    }
  }

  if( !defined($host) || $host eq '' ) {
    Log3 $name, 3, 'HUEBridge_Detect: error detecting bridge.';
    return;
  }

  Log3 $name, 3, "HUEBridge_Detect: ${host}";
  $hash->{Host} = $host;

  return $host;
}

sub
HUEBridge_Define($$)
{
  my ($hash, $def) = @_;

  my @args = split("[ \t]+", $def);

  return "Usage: define <name> HUEBridge [<host>] [interval]"  if(@args < 2);

  my ($name, $type, $host, $interval) = @args;

  if( !defined($host) ) {
    $hash->{NUPNP} = 1;
    HUEBridge_Detect($hash);
  } else {
    delete $hash->{NUPNP};
  }

  $interval= 60 unless defined($interval);
  if( $interval < 10 ) { $interval = 10; }

  readingsSingleUpdate($hash, 'state', 'initialized', 1 );

  $hash->{Host} = $host;
  $hash->{INTERVAL} = $interval;

  $attr{$name}{"key"} = join "",map { unpack "H*", chr(rand(256)) } 1..16 unless defined( AttrVal($name, "key", undef) );

  $hash->{helper}{last_config_timestamp} = 0;

  if( !defined($hash->{helper}{count}) ) {
    $modules{$hash->{TYPE}}{helper}{count} = 0 if( !defined($modules{$hash->{TYPE}}{helper}{count}) );
    $hash->{helper}{count} =  $modules{$hash->{TYPE}}{helper}{count}++;
  }

  $hash->{NOTIFYDEV} = "global";

  if( $init_done ) {
    HUEBridge_OpenDev( $hash ) if( !IsDisabled($name) );
  }

  return undef;
}
sub
HUEBridge_Notify($$)
{
  my ($hash,$dev) = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};

  return if($dev->{NAME} ne "global");
  return if(!grep(m/^INITIALIZED|REREADCFG$/, @{$dev->{CHANGED}}));

  if( IsDisabled($name) > 0 ) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1 ) if( ReadingsVal($name,'state','' ) ne 'disabled' );
    return undef;
  }

  HUEBridge_OpenDev($hash);

  return undef;
}

sub HUEBridge_Undefine($$)
{
  my ($hash,$arg) = @_;

  RemoveInternalTimer($hash);
  return undef;
}

sub HUEBridge_fillBridgeInfo($$)
{
  my ($hash,$config) = @_;
  my $name = $hash->{NAME};

  $hash->{name} = $config->{name};
  $hash->{modelid} = $config->{modelid};
  $hash->{swversion} = $config->{swversion};
  $hash->{apiversion} = $config->{apiversion};

  if( $hash->{apiversion} ) {
    my @l = split( '\.', $config->{apiversion} );
    $hash->{helper}{apiversion} = ($l[0] << 16) + ($l[1] << 8) + $l[2];
  }

  if( !defined($config->{'linkbutton'})
      && !defined($attr{$name}{icon}) ) {
    $attr{$name}{icon} = 'hue_filled_bridge_v1' if( $hash->{modelid} && $hash->{modelid} eq 'BSB001' );
    $attr{$name}{icon} = 'hue_filled_bridge_v2' if( $hash->{modelid} && $hash->{modelid} eq 'BSB002' );
  }

  $hash->{noshutdown} = AttrVal($name,'noshutdown', $hash->{name} =~ /deCONZ-GW|RaspBee/i)?1:0 if( !defined($hash->{noshutdown} ) );
}

sub
HUEBridge_OpenDev($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  HUEBridge_Detect($hash) if( defined($hash->{NUPNP}) );

  my ($err,$ret) = HttpUtils_BlockingGet({
    url => "http://$hash->{Host}/description.xml",
    method => "GET",
    timeout => 3,
  });

  if( defined($err) && $err ) {
    Log3 $name, 2, "HUEBridge_OpenDev: error reading description: ". $err;
  } else {
    Log3 $name, 5, "HUEBridge_OpenDev: got description: $ret";
    $ret =~ m/<modelName>([^<]*)/;
    $hash->{modelName} = $1;
    $ret =~ m/<manufacturer>([^<]*)/;
    $hash->{manufacturer} = $1;

    if( $hash->{manufacturer} =~ /dresden elektronik/i ) {
      $hash->{noshutdown} = AttrVal($name, 'noshutdown', 1)?1:0;
    }
  }

  my $result = HUEBridge_Call($hash, undef, 'config', undef);
  if( !defined($result) ) {
    Log3 $name, 2, "HUEBridge_OpenDev: got empty config";
    return undef;
  }
  Log3 $name, 5, "HUEBridge_OpenDev: got config " . Dumper $result;

  if( !defined($result->{'linkbutton'}) || !AttrVal($name, 'key', undef) )
    {
      HUEBridge_fillBridgeInfo($hash, $result);

      HUEBridge_Pair($hash);
      return;
    }

  $hash->{mac} = $result->{'mac'};

  readingsSingleUpdate($hash, 'state', 'connected', 1 );
  HUEBridge_GetUpdate($hash);

  HUEBridge_Autocreate($hash);

  return undef;
}
sub HUEBridge_Pair($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  readingsSingleUpdate($hash, 'state', 'pairing', 1 );

  my $result = HUEBridge_Register($hash);
  if( $result->{'error'} )
    {
      RemoveInternalTimer($hash);
      InternalTimer(gettimeofday()+5, "HUEBridge_Pair", $hash, 0);

      return undef;
    }

  $attr{$name}{key} = $result->{success}{username} if( $result->{success}{username} );

  readingsSingleUpdate($hash, 'state', 'paired', 1 );

  HUEBridge_OpenDev($hash);

  return undef;
}

sub
HUEBridge_string2array($)
{
  my ($lights) = @_;

  my %lights = ();
  foreach my $part ( split(',', $lights) ) {
    my $light = $part;
    $light = $defs{$light}{ID} if( defined $defs{$light} && $defs{$light}{TYPE} eq 'HUEDevice' );
    if( $light =~ m/^G/ ) {
      my $lights = $defs{$part}->{lights};
      if( $lights ) {
        foreach my $light ( split(',', $lights) ) {
          $lights{$light} = 1;
        }
      }
    } else {
      $lights{$light} = 1;
    }
  }

  my @lights = sort {$a<=>$b} keys(%lights);
  return \@lights;
}

sub
HUEBridge_Set($@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my ($arg, @params) = @args;

  $hash->{".triggerUsed"} = 1;

  return "$name: not paired" if( ReadingsVal($name, 'state', '' ) =~ m/^link/ );
  #return "$name: not connected" if( $hash->{STATE} ne 'connected'  );

  # usage check
  if($cmd eq 'statusRequest') {
    return "usage: statusRequest" if( @args != 0 );

    $hash->{LOCAL} = 1;
    #RemoveInternalTimer($hash);
    HUEBridge_GetUpdate($hash);
    delete $hash->{LOCAL};
    return undef;

  } elsif($cmd eq 'swupdate') {
    return "usage: swupdate" if( @args != 0 );

    my $obj = {
      'swupdate' => { 'updatestate' => 3, },
    };
    my $result = HUEBridge_Call($hash, undef, 'config', $obj);

    if( !defined($result) || $result->{'error'} ) {
      return $result->{'error'}->{'description'};
    }

    $hash->{updatestate} = 3;
    $hash->{helper}{updatestate} = $hash->{updatestate};
    readingsSingleUpdate($hash, 'state', 'updating', 1 );
    return "starting update";

  } elsif($cmd eq 'autocreate') {
    return "usage: autocreate" if( @args != 0 );

    return HUEBridge_Autocreate($hash,1);

  } elsif($cmd eq 'autodetect') {
    return "usage: autodetect" if( @args != 0 );

    my $result = HUEBridge_Call($hash, undef, 'lights', undef, 'POST');
    return $result->{error}{description} if( $result->{error} );

    return $result->{success}{'/lights'} if( $result->{success} );

    return undef;

  } elsif($cmd eq 'delete') {
    return "usage: delete <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'HUEDevice' ) {
      $arg = $defs{$arg}{ID};
    }
    return "$arg is not a hue light number" if( $arg !~ m/^\d+$/ );

    my $code = $name ."-". $arg;
    if( defined($modules{HUEDevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{HUEDevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    my $result = HUEBridge_Call($hash, undef, "lights/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'creategroup') {
    return "usage: creategroup <name> <lights>" if( @args < 2 );

    my $obj = { 'name' => join( ' ', @args[0..@args-2]),
                'lights' => HUEBridge_string2array($args[@args-1]),
    };

    my $result = HUEBridge_Call($hash, undef, 'groups', $obj, 'POST');
    return $result->{error}{description} if( $result->{error} );

    if( $result->{success} ) {
      HUEBridge_Autocreate($hash);

      my $code = $name ."-G". $result->{success}{id};
      return "created $modules{HUEDevice}{defptr}{$code}->{NAME}" if( defined($modules{HUEDevice}{defptr}{$code}) );
    }

    return undef;

  } elsif($cmd eq 'deletegroup') {
    return "usage: deletegroup <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'HUEDevice' ) {
      return "$arg is not a hue group" if( $defs{$arg}{ID} != m/^G/ );
      $defs{$arg}{ID} =~ m/G(.*)/;
      $arg = $1;
    }

    my $code = $name ."-G". $arg;
    if( defined($modules{HUEDevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{HUEDevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "$arg is not a hue group number" if( $arg !~ m/^\d+$/ );

    my $result = HUEBridge_Call($hash, undef, "groups/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'savescene') {
    my $result;
    if( $hash->{helper}{apiversion} && $hash->{helper}{apiversion} >= (1<<16) + (11<<8) ) {
      return "usage: savescene <name> <lights>" if( @args < 2 );

      my $obj = { 'name' => join( ' ', @args[0..@args-2]),
                  'recycle' => JSON::true,
                  'lights' => HUEBridge_string2array($args[@args-1]),
      };

      $result = HUEBridge_Call($hash, undef, "scenes", $obj, 'POST');

    } else {
      return "usage: savescene <id> <name> <lights>" if( @args < 3 );

      my $obj = { 'name' => join( ' ', @args[1..@args-2]),
                  'lights' => HUEBridge_string2array($args[@args-1]),
      };
      $result = HUEBridge_Call($hash, undef, "scenes/$arg", $obj, 'PUT');

    }
    return $result->{error}{description} if( $result->{error} );

    if( $result->{success} ) {
      return "created $result->{success}{id}" if( $result->{success}{id} );
      return "created $arg";
    }

    return undef;

  } elsif($cmd eq 'modifyscene') {
    return "usage: modifyscene <id> <light> <light args>" if( @args < 3 );

    my( $light, @aa ) = @params;
    $light = $defs{$light}{ID} if( defined $defs{$light} && $defs{$light}{TYPE} eq 'HUEDevice' );

    my %obj;
    if( (my $joined = join(" ", @aa)) =~ /:/ ) {
      my @cmds = split(":", $joined);
      for( my $i = 0; $i <= $#cmds; ++$i ) {
        HUEDevice_SetParam(undef, \%obj, split(" ", $cmds[$i]) );
      }
    } else {
      my ($cmd, $value, $value2, @a) = @aa;

      HUEDevice_SetParam(undef, \%obj, $cmd, $value, $value2);
    }

    my $result = HUEBridge_Call($hash, undef, "scenes/$arg/lights/$light/state", \%obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'deletescene') {
    return "usage: deletescene <id>" if( @args != 1 );

    my $result = HUEBridge_Call($hash, undef, "scenes/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'scene') {
    return "usage: scene <id>" if( @args != 1 );

    my $obj = { 'scene' => $arg };
    my $result = HUEBridge_Call($hash, undef, "groups/0/action", $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+10, "HUEBridge_GetUpdate", $hash, 0);

    return undef;

  } elsif($cmd eq 'createrule' || $cmd eq 'updaterule') {
    return "usage: createrule <name> <conditions&actions json>" if( $cmd eq 'createrule' && @args < 2 );
    return "usage: updaterule <id> <conditions&actions json>" if( $cmd eq 'updaterule' && @args != 2 );

    $args[@args-1] = '
{  "name":"Wall Switch Rule",
   "conditions":[
        {"address":"/sensors/1/state/lastupdated","operator":"dx"}
   ],
   "actions":[
        {"address":"/groups/0/action","method":"PUT", "body":{"scene":"S3"}}
]}' if( 0 || !$args[@args-1] );
    my $json = $args[@args-1];
    my $obj = eval { decode_json($json) };
    if( $@ ) {
      Log3 $name, 2, "$name: json error: $@ in $json";
      return undef;
    }

    my $result;
    if( $cmd eq 'updaterule' ) {
     $result = HUEBridge_Call($hash, undef, "rules/$args[0]", $obj, 'PUT');
    } else {
     $obj->{name} = join( ' ', @args[0..@args-2]);
     $result = HUEBridge_Call($hash, undef, 'rules', $obj, 'POST');
    }
    return $result->{error}{description} if( $result->{error} );

    return "created rule id $result->{success}{id}" if( $result->{success} && $result->{success}{id} );

    return undef;

  } elsif($cmd eq 'deleterule') {
    return "usage: deleterule <id>" if( @args != 1 );
    return "$arg is not a hue rule number" if( $arg !~ m/^\d+$/ );

    my $result = HUEBridge_Call($hash, undef, "rules/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'createsensor') {
    return "usage: createsensor <name> <type> <uniqueid> <swversion> <modelid>" if( @args < 5 );

    return "usage: type must be one of: Switch OpenClose Presence Temperature Humidity GenericFlag GenericStatus " if( $args[@args-4] !~ m/Switch|OpenClose|Presence|Temperature|Humidity|Lightlevel|GenericFlag|GenericStatus/ );

    my $obj = { 'name' => join( ' ', @args[0..@args-5]),
                'type' => "CLIP$args[@args-4]",
                'uniqueid' => $args[@args-3],
                'swversion' => $args[@args-2],
                'modelid' => $args[@args-1],
                'manufacturername' => 'FHEM-HUE',
              };

    my $result = HUEBridge_Call($hash, undef, 'sensors', $obj, 'POST');
    return $result->{error}{description} if( $result->{error} );

    return "created sensor id $result->{success}{id}" if( $result->{success} );

#    if( $result->{success} ) {
#      my $code = $name ."-S". $result->{success}{id};
#      my $devname = "HUEDevice" . $id;
#      $devname = $name ."_". $devname if( $hash->{helper}{count} );
#      my $define = "$devname HUEDevice sensor $id IODev=$name";
#
#      Log3 $name, 4, "$name: create new device '$devname' for address '$id'";
#
#      my $cmdret= CommandDefine(undef,$define);
#
#      return "created $modules{HUEDevice}{defptr}{$code}->{NAME}" if( defined($modules{HUEDevice}{defptr}{$code}) );
#    }

    return undef;

  } elsif($cmd eq 'deletesensor') {
    return "usage: deletesensor <id>" if( @args != 1 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'HUEDevice' ) {
      return "$arg is not a hue sensor" if( $defs{$arg}{ID} !~ m/^S/ );
      $defs{$arg}{ID} =~ m/S(.*)/;
      $arg = $1;
    }

    my $code = $name ."-S". $arg;
    if( defined($modules{HUEDevice}{defptr}{$code}) ) {
      CommandDelete( undef, "$modules{HUEDevice}{defptr}{$code}{NAME}" );
      CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
    }

    return "$arg is not a hue sensor number" if( $arg !~ m/^\d+$/ );

    my $result = HUEBridge_Call($hash, undef, "sensors/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'configsensor' || $cmd eq 'setsensor') {
    return "usage: $cmd <id> <json>" if( @args < 2 );

    if( defined $defs{$arg} && $defs{$arg}{TYPE} eq 'HUEDevice' ) {
      return "$arg is not a hue sensor" if( $defs{$arg}{ID} !~ m/^S/ );
      $defs{$arg}{ID} =~ m/S(.*)/;
      $arg = $1;
    }
    return "$arg is not a hue sensor number" if( $arg !~ m/^\d+$/ );

    my $json = join( ' ', @args[1..@args-1]);
    my $decoded = eval { decode_json($json) };
    if( $@ ) {
      Log3 $name, 2, "$name: json error: $@ in $json";
      return undef;
    }
    $json = $decoded;

    my $result = HUEBridge_Call($hash, undef, "sensors/$arg/".($cmd eq 'configsensor'?'config':'state'), $json, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    my $code = $name ."-S". $arg;
    if( my $chash = $modules{HUEDevice}{defptr}{$code} ) {
      HUEDevice_GetUpdate($chash);
    }

    return undef;

  } elsif($cmd eq 'deletewhitelist') {
    return "usage: deletewhitelist <key>" if( @args != 1 );

    my $result = HUEBridge_Call($hash, undef, "config/whitelist/$arg", undef, 'DELETE');
    return $result->{error}{description} if( $result->{error} );

    return undef;

  } elsif($cmd eq 'touchlink') {
    return "usage: touchlink" if( @args != 0 );

    my $obj = { 'touchlink' => JSON::true };

    my $result = HUEBridge_Call($hash, undef, 'config', $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    return undef if( $result->{success} );

    return undef;

  } elsif($cmd eq 'checkforupdate') {
    return "usage: checkforupdate" if( @args != 0 );

    my $obj = { swupdate => {'checkforupdate' => JSON::true } };

    my $result = HUEBridge_Call($hash, undef, 'config', $obj, 'PUT');
    return $result->{error}{description} if( $result->{error} );

    return undef if( $result->{success} );

    return undef;


  } else {
    my $list = "delete creategroup deletegroup savescene deletescene modifyscene scene createrule updaterule deleterule createsensor deletesensor configsensor setsensor deletewhitelist touchlink:noArg checkforupdate:noArg autodetect:noArg autocreate:noArg statusRequest:noArg";
    $list .= " swupdate:noArg" if( defined($hash->{updatestate}) && $hash->{updatestate} =~ '^2' );
    return "Unknown argument $cmd, choose one of $list";
  }
}

sub
HUEBridge_Get($@)
{
  my ($hash, $name, $cmd, @args) = @_;
  my ($arg, @params) = @args;

  return "$name: not paired" if( ReadingsVal($name, 'state', '' ) =~ m/^link/ );
  #return "$name: not connected" if( $hash->{STATE} ne 'connected'  );
  return "$name: get needs at least one parameter" if( !defined($cmd) );

  # usage check
  if($cmd eq 'devices'
     || $cmd eq 'lights') {
    my $result =  HUEBridge_Call($hash, undef, 'lights', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-". $key;
      my $fhem_name ="";
      $fhem_name = $modules{HUEDevice}{defptr}{$code}->{NAME} if( defined($modules{HUEDevice}{defptr}{$code}) );
      $ret .= sprintf( "%2i: %-25s %-15s %s\n", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type} );
    }
    $ret = sprintf( "%2s  %-25s %-15s %s\n", "ID", "NAME", "FHEM", "TYPE" ) .$ret if( $ret );
    return $ret;

  } elsif($cmd eq 'groups') {
    my $result =  HUEBridge_Call($hash, undef, 'groups', undef);
    return $result->{error}{description} if( $result->{error} );
    $result->{0} = { name => 'Lightset 0', type => 'LightGroup', lights => ["ALL"] };
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-G". $key;
      my $fhem_name ="";
      $fhem_name = $modules{HUEDevice}{defptr}{$code}->{NAME} if( defined($modules{HUEDevice}{defptr}{$code}) );
      $result->{$key}{type} = '' if( !defined($result->{$key}{type}) );     #deCONZ fix
      $result->{$key}{class} = '' if( !defined($result->{$key}{class}) );   #deCONZ fix
      $result->{$key}{lights} = [] if( !defined($result->{$key}{lights}) ); #deCONZ fix
      $ret .= sprintf( "%2i: %-15s %-15s %-15s %-15s %s\n", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type}, $result->{$key}{class}, join( ",", @{$result->{$key}{lights}} ) );
    }
    $ret = sprintf( "%2s  %-15s %-15s %-15s %-15s %s\n", "ID", "NAME", "FHEM", "TYPE", "CLASS", "LIGHTS" ) .$ret if( $ret );
    return $ret;

  } elsif($cmd eq 'scenes') {
    my $result =  HUEBridge_Call($hash, undef, 'scenes', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a cmp $b} keys %{$result} ) {
      $ret .= sprintf( "%-20s %-20s", $key, $result->{$key}{name} );
      $ret .= sprintf( "%i %i %i %-40s %-20s", $result->{$key}{recycle}, $result->{$key}{locked},$result->{$key}{version}, $result->{$key}{owner}, $result->{$key}{lastupdated}?$result->{$key}{lastupdated}:'' ) if( $arg && $arg eq 'detail' );
      $ret .= sprintf( " %s\n", join( ",", @{$result->{$key}{lights}} ) );
    }
    if( $ret ) {
      my $header = sprintf( "%-20s %-20s", "ID", "NAME" );
      $header .= sprintf( "%s %s %s %-40s %-20s", "R", "L", "V", "OWNER", "LAST UPDATE" ) if( $arg && $arg eq 'detail' );
      $header .= sprintf( " %s\n", "LIGHTS" );
      $ret = $header . $ret;
    }
    return $ret;

  } elsif($cmd eq 'rule') {
    return "usage: rule <id>" if( @args != 1 );
    return "$arg is not a hue rule number" if( $arg !~ m/^\d+$/ );

    my $result =  HUEBridge_Call($hash, undef, "rules/$arg", undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = encode_json($result->{conditions}) ."\n". encode_json($result->{actions});
    return $ret;

  } elsif($cmd eq 'rules') {
    my $result =  HUEBridge_Call($hash, undef, 'rules', undef);
    return $result->{error}{description} if( $result->{error} );

    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      $ret .= sprintf( "%2i: %-20s", $key, $result->{$key}{name} );
      $ret .= sprintf( " %s", encode_json($result->{$key}{conditions}) ) if( $arg && $arg eq 'detail' );
      $ret .= sprintf( "\n%-24s %s", "", encode_json($result->{$key}{actions}) ) if( $arg && $arg eq 'detail' );
      $ret .= "\n";
    }
    if( $arg && $arg eq 'detail' ) {
      $ret = sprintf( "%2s  %-20s %s\n", "ID", "NAME", "CONDITIONS/ACTIONS" ) .$ret if( $ret );
    } else {
      $ret = sprintf( "%2s  %-20s\n", "ID", "NAME" ) .$ret if( $ret );
    }
    return $ret;

  } elsif($cmd eq 'sensors') {
    my $result =  HUEBridge_Call($hash, undef, 'sensors', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    foreach my $key ( sort {$a<=>$b} keys %{$result} ) {
      my $code = $name ."-S". $key;
      my $fhem_name ="";
      $fhem_name = $modules{HUEDevice}{defptr}{$code}->{NAME} if( defined($modules{HUEDevice}{defptr}{$code}) );
      $ret .= sprintf( "%2i: %-15s %-15s %-20s", $key, $result->{$key}{name}, $fhem_name, $result->{$key}{type} );
      $ret .= sprintf( " %s", encode_json($result->{$key}{state}) ) if( $arg && $arg eq 'detail' );
      $ret .= "\n";
    }
    if( $arg && $arg eq 'detail' ) {
      $ret = sprintf( "%2s  %-15s %-15s %-20s %s\n", "ID", "NAME", "FHEM", "TYPE", "STATE" ) .$ret if( $ret );
    } else {
      $ret = sprintf( "%2s  %-15s %-15s %-20s\n", "ID", "NAME", "FHEM", "TYPE" ) .$ret if( $ret );
    }
    return $ret;

  } elsif($cmd eq 'whitelist') {
    my $result =  HUEBridge_Call($hash, undef, 'config', undef);
    return $result->{error}{description} if( $result->{error} );
    my $ret = "";
    my $whitelist = $result->{whitelist};
    foreach my $key ( sort {$whitelist->{$a}{'last use date'} cmp $whitelist->{$b}{'last use date'}} keys %{$whitelist} ) {
      $ret .= sprintf( "%-20s %-20s %-30s %s\n", $whitelist->{$key}{'create date'}, , $whitelist->{$key}{'last use date'}, $whitelist->{$key}{name}, $key );
    }
    $ret = sprintf( "%-20s %-20s %-30s %s\n", "CREATE", "LAST USE", "NAME", "KEY" ) .$ret if( $ret );
    return $ret;

  } else {
    return "Unknown argument $cmd, choose one of lights:noArg groups:noArg scenes:noArg rule rules:noArg sensors:noArg whitelist:noArg";
  }
}

sub
HUEBridge_GetUpdate($)
{
  my ($hash) = @_;
  my $name = $hash->{NAME};

  if(!$hash->{LOCAL}) {
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "HUEBridge_GetUpdate", $hash, 0);
  }

  my $type;
  my $result;
  if( AttrVal($name,"pollDevices",1) ) {
    my ($now) = gettimeofday();
    if( $hash->{LOCAL} || $now - $hash->{helper}{last_config_timestamp} > 300 ) {
      $result = HUEBridge_Call($hash, $hash, undef, undef);
      $hash->{helper}{last_config_timestamp} = $now;
    } else {
      $type = 'lights';
      $result = HUEBridge_Call($hash, $hash, 'lights', undef);
    }
  } else {
    $type = 'config';
    $result = HUEBridge_Call($hash, $hash, 'config', undef);
  }

  return undef if( !defined($result) );

  HUEBridge_dispatch( {hash=>$hash,chash=>$hash,type=>$type}, undef, undef, $result );

  #HUEBridge_Parse($hash, $result);

  return undef;
}

sub
HUEBridge_Parse($$)
{
  my($hash,$config) = @_;
  my $name = $hash->{NAME};

  Log3 $name, 4, "parse status message for $name";
  #Log3 $name, 5, Dumper $config;

  #Log 3, Dumper $config;
  $config = $config->{config} if( defined($config->{config}) );

  HUEBridge_fillBridgeInfo($hash, $config);

  $hash->{zigbeechannel} = $config->{zigbeechannel};

  if( my $utc = $config->{UTC} ) {
    substr( $utc, 10, 1, '_' );

    if( my $localtime = $config->{localtime} ) {
      $localtime = TimeNow() if( $localtime eq 'none' );
      substr( $localtime, 10, 1, '_' );

      $hash->{helper}{offsetUTC} = SVG_time_to_sec($localtime) - SVG_time_to_sec($utc);

    } else {
      Log3 $name, 2, "$name: missing localtime configuration";

    }
  }

  if( defined( $config->{swupdate} ) ) {
    my $txt = $config->{swupdate}->{text};
    readingsSingleUpdate($hash, "swupdate", $txt, 1) if( $txt && $txt ne ReadingsVal($name,"swupdate","") );
    if( defined($hash->{updatestate}) ){
      readingsSingleUpdate($hash, 'state', 'update done', 1 ) if( $config->{swupdate}->{updatestate} == 0 &&  $hash->{helper}{updatestate} >= 2 );
      readingsSingleUpdate($hash, 'state', 'update failed', 1 ) if( $config->{swupdate}->{updatestate} == 2 &&  $hash->{helper}{updatestate} == 3 );
    }

    $hash->{updatestate} = $config->{swupdate}->{updatestate};
    $hash->{helper}{updatestate} = $hash->{updatestate};
    if( $config->{swupdate}->{devicetypes} ) {
      my $devicetypes;
      $devicetypes .= 'bridge' if( $config->{swupdate}->{devicetypes}->{bridge} );
      $devicetypes .= ',' if( $devicetypes && scalar(@{$config->{swupdate}->{devicetypes}->{lights}}) );
      $devicetypes .= join( ",", @{$config->{swupdate}->{devicetypes}->{lights}} ) if( $config->{swupdate}->{devicetypes}->{lights} );

      $hash->{updatestate} .= " [$devicetypes]" if( $devicetypes );
    }
  } elsif ( defined(  $hash->{swupdate} ) ) {
    delete( $hash->{updatestate} );
    delete( $hash->{helper}{updatestate} );
  }

  readingsSingleUpdate($hash, 'state', $hash->{READINGS}{state}{VAL}, 0);
}

sub
HUEBridge_Autocreate($;$)
{
  my ($hash,$force)= @_;
  my $name = $hash->{NAME};

  if( !$force ) {
    foreach my $d (keys %defs) {
      next if($defs{$d}{TYPE} ne "autocreate");
      return undef if(AttrVal($defs{$d}{NAME},"disable",undef));
    }
  }

  my $autocreated = 0;
  my $result =  HUEBridge_Call($hash,undef, 'lights', undef);
  foreach my $key ( keys %{$result} ) {
    my $id= $key;

    my $code = $name ."-". $id;
    if( defined($modules{HUEDevice}{defptr}{$code}) ) {
      Log3 $name, 5, "$name: id '$id' already defined as '$modules{HUEDevice}{defptr}{$code}->{NAME}'";
      next;
    }

    my $devname = "HUEDevice" . $id;
    $devname = $name ."_". $devname if( $hash->{helper}{count} );
    my $define= "$devname HUEDevice $id IODev=$name";

    Log3 $name, 4, "$name: create new device '$devname' for address '$id'";

    my $cmdret= CommandDefine(undef,$define);
    if($cmdret) {
      Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$id': $cmdret";
    } else {
      $cmdret= CommandAttr(undef,"$devname alias ".$result->{$id}{name});
      $cmdret= CommandAttr(undef,"$devname room HUEDevice");
      $cmdret= CommandAttr(undef,"$devname IODev $name");

      HUEDeviceSetIcon($devname);
      $defs{$devname}{helper}{fromAutocreate} = 1 ;

      $autocreated++;
    }
  }

  $result =  HUEBridge_Call($hash,undef, 'groups', undef);
  $result->{0} = { name => "Lightset 0", };
  foreach my $key ( keys %{$result} ) {
    my $id= $key;

    my $code = $name ."-G". $id;
    if( defined($modules{HUEDevice}{defptr}{$code}) ) {
      Log3 $name, 5, "$name: id '$id' already defined as '$modules{HUEDevice}{defptr}{$code}->{NAME}'";
      next;
    }

    my $devname= "HUEGroup" . $id;
    $devname = $name ."_". $devname if( $hash->{helper}{count} );
    my $define= "$devname HUEDevice group $id IODev=$name";

    Log3 $name, 4, "$name: create new group '$devname' for address '$id'";

    my $cmdret= CommandDefine(undef,$define);
    if($cmdret) {
      Log3 $name, 1, "$name: Autocreate: An error occurred while creating device for id '$id': $cmdret";
    } else {
      $cmdret= CommandAttr(undef,"$devname alias ".$result->{$id}{name});
      $cmdret= CommandAttr(undef,"$devname room HUEDevice");
      $cmdret= CommandAttr(undef,"$devname group HUEGroup");
      $cmdret= CommandAttr(undef,"$devname IODev $name");

      HUEDeviceSetIcon($devname);
      $defs{$devname}{helper}{fromAutocreate} = 1 ;

      $autocreated++;
    }
  }

  if( $autocreated ) {
    Log3 $name, 2, "$name: autocreated $autocreated devices";
    CommandSave(undef,undef) if( AttrVal( "autocreate", "autosave", 1 ) );
  }

  return "created $autocreated devices";
}

sub HUEBridge_ProcessResponse($$)
{
  my ($hash,$obj) = @_;
  my $name = $hash->{NAME};

  #Log3 $name, 3, ref($obj);
  #Log3 $name, 3, "Receiving: " . Dumper $obj;

  if( ref($obj) eq 'ARRAY' )
    {
      if( defined($obj->[0]->{error}))
        {
          my $error = $obj->[0]->{error}->{'description'};

          readingsSingleUpdate($hash, 'lastError', $error, 0 );
        }

    if( !AttrVal( $name,'queryAfterSet', 1 ) ) {
      my $successes;
      my $errors;
      my %json = ();
      foreach my $item (@{$obj}) {
        if( my $success = $item->{success} ) {
          next if( ref($success) ne 'HASH' );
          foreach my $key ( keys %{$success} ) {
            my @l = split( '/', $key );
            next if( !$l[1] );
            if( $l[1] eq 'lights' && $l[3] eq 'state' ) {
              $json{$l[2]}->{state}->{$l[4]} = $success->{$key};
              $successes++;

            } elsif( $l[1] eq 'groups' && $l[3] eq 'action' ) {
              my $code = $name ."-G". $l[2];
              my $d = $modules{HUEDevice}{defptr}{$code};
              my $lights = $d->{lights};
              foreach my $light ( split(',', $lights) ) {
                $json{$light}->{state}->{$l[4]} = $success->{$key};
                $successes++;
              }

            }
          }

        } elsif( my $error = $item->{error} ) {
          my $msg = $error->{'description'};
          Log3 $name, 3, $msg;
          $errors++;
        }
      }

      foreach my $id ( keys %json ) {
        my $code = $name ."-". $id;
        if( my $chash = $modules{HUEDevice}{defptr}{$code} ) {
          #$json{$id}->{state}->{reachable} = 1;
          HUEDevice_Parse( $chash, $json{$id} );
        }
      }
    }

      #return undef if( !$errors && $successes );

      return ($obj->[0]);
    }
  elsif( ref($obj) eq 'HASH' )
    {
      return $obj;
    }

  return undef;
}

sub HUEBridge_Register($)
{
  my ($hash) = @_;

  my $obj = {
    'devicetype' => 'fhem',
  };

  if( !$hash->{helper}{apiversion} || $hash->{helper}{apiversion} < (1<<16) + (12<<8) ) {
    $obj->{username} = AttrVal($hash->{NAME}, 'key', '');
  }

  return HUEBridge_Call($hash, undef, undef, $obj);
}

#Executes a JSON RPC
sub
HUEBridge_Call($$$$;$)
{
  my ($hash,$chash,$path,$obj,$method) = @_;
  my $name = $hash->{NAME};

  if( IsDisabled($name) ) {
    readingsSingleUpdate($hash, 'state', 'disabled', 1 ) if( ReadingsVal($name,'state','' ) ne 'disabled' );
    return undef;
  }

  #Log3 $hash->{NAME}, 5, "Sending: " . Dumper $obj;

  my $json = undef;
  $json = encode_json($obj) if $obj;

  # @TODO: repeat twice?
  for( my $attempt=0; $attempt<2; $attempt++ ) {
    my $blocking;
    my $res = undef;
    if( !defined($attr{$name}{httpUtils}) ) {
      $blocking = 1;
      $res = HUEBridge_HTTP_Call($hash,$path,$json,$method);
    } else {
      $blocking = $attr{$name}{httpUtils} < 1;
      $res = HUEBridge_HTTP_Call2($hash,$chash,$path,$json,$method);
    }

    return $res if( !$blocking || defined($res) );

    Log3 $name, 3, "HUEBridge_Call: failed, retrying";
    HUEBridge_Detect($hash) if( defined($hash->{NUPNP}) );
  }

  Log3 $name, 3, "HUEBridge_Call: failed";
  return undef;
}

#JSON RPC over HTTP
sub
HUEBridge_HTTP_Call($$$;$)
{
  my ($hash,$path,$obj,$method) = @_;
  my $name = $hash->{NAME};

  #return { state => {reachable => 0 } } if($attr{$name} && $attr{$name}{disable});

  my $uri = "http://" . $hash->{Host} . "/api";
  if( defined($obj) ) {
    $method = 'PUT' if( !$method );

    if( ReadingsVal($name, 'state', '') eq 'pairing' ) {
      $method = 'POST';
    } else {
      $uri .= "/" . AttrVal($name, "key", "");
    }
  } else {
    $uri .= "/" . AttrVal($name, "key", "");
  }
  $method = 'GET' if( !$method );
  if( defined $path) {
    $uri .= "/" . $path;
  }
  #Log3 $name, 3, "Url: " . $uri;
  Log3 $name, 4, "using HUEBridge_HTTP_Request: $method ". ($path?$path:'');
  my $ret = HUEBridge_HTTP_Request(0,$uri,$method,undef,$obj,$hash->{noshutdown});
  #Log3 $name, 3, Dumper $ret;
  if( !defined($ret) ) {
    return undef;
  } elsif($ret eq '') {
    return undef;
  } elsif($ret =~ /^error:(\d){3}$/) {
    my %result = { error => "HTTP Error Code $1" };
    return \%result;
  }

  if( !$ret ) {
    Log3 $name, 2, "$name: empty answer received for $uri";
    return undef;
  } elsif( $ret =~ m'HTTP/1.1 200 OK' ) {
    Log3 $name, 4, "$name: empty answer received for $uri";
    return undef;
  } elsif( $ret !~ m/^[\[{].*[\]}]$/ ) {
    Log3 $name, 2, "$name: invalid json detected for $uri: $ret";
    return undef;
  }

  my $decoded;
  if( HUEBridge_isFritzBox() ) {
    $decoded = eval { decode_json($ret) };
    Log3 $name, 2, "$name: json error: $@ in $ret" if( $@ );
  } else {
    $decoded = eval { from_json($ret) };
    Log3 $name, 2, "$name: json error: $@ in $ret" if( $@ );
  }

  return HUEBridge_ProcessResponse($hash, $decoded);
}

sub
HUEBridge_HTTP_Call2($$$$;$)
{
  my ($hash,$chash,$path,$obj,$method) = @_;
  my $name = $hash->{NAME};

  #return { state => {reachable => 0 } } if($attr{$name} && $attr{$name}{disable});

  my $url = "http://" . $hash->{Host} . "/api";
  my $blocking = $attr{$name}{httpUtils} < 1;
  $blocking = 1 if( !defined($chash) );
  if( defined($obj) ) {
    $method = 'PUT' if( !$method );

    if( ReadingsVal($name, 'state', '') eq 'pairing' ) {
      $method = 'POST';
      $blocking = 1;
    } else {
      $url .= "/" . AttrVal($name, "key", "");
    }
  } else {
    $url .= "/" . AttrVal($name, "key", "");
  }
  $method = 'GET' if( !$method );

  if( defined $path) {
    $url .= "/" . $path;
  }
  #Log3 $name, 3, "Url: " . $url;

#Log 2, $path;
  if( $blocking ) {
    Log3 $name, 4, "using HttpUtils_BlockingGet: $method ". ($path?$path:'');

    my($err,$data) = HttpUtils_BlockingGet({
      url => $url,
      timeout => 4,
      method => $method,
      noshutdown => $hash->{noshutdown},
      header => "Content-Type: application/json",
      data => $obj,
    });

    if( !$data ) {
      Log3 $name, 2, "$name: empty answer received for $url";
      return undef;
    } elsif( $data =~ m'HTTP/1.1 200 OK' ) {
      Log3 $name, 4, "$name: empty answer received for $url";
      return undef;
    } elsif( $data !~ m/^[\[{].*[\]}]$/ ) {
      Log3 $name, 2, "$name: invalid json detected for $url: $data";
      return undef;
    }

    my $json = eval { from_json($data) };
    Log3 $name, 2, "$name: json error: $@ in $data" if( $@ );
    return undef if( !$json );

    return HUEBridge_ProcessResponse($hash, $json);

    HUEBridge_dispatch( {hash=>$hash,chash=>$chash,type=>$path},$err,$data );
  } else {
    Log3 $name, 4, "using HttpUtils_NonblockingGet: $method ". ($path?$path:'');

    my($err,$data) = HttpUtils_NonblockingGet({
      url => $url,
      timeout => 10,
      method => $method,
      noshutdown => $hash->{noshutdown},
      header => "Content-Type: application/json",
      data => $obj,
      hash => $hash,
      chash => $chash,
      type => $path,
      callback => \&HUEBridge_dispatch,
    });

    return undef;
  }
}

sub
HUEBridge_dispatch($$$;$)
{
  my ($param, $err, $data, $json) = @_;
  my $hash = $param->{hash};
  my $name = $hash->{NAME};

  #Log3 $name, 5, "HUEBridge_dispatch";

  if( $err ) {
    Log3 $name, 2, "$name: http request failed: $err";
  } elsif( $data || $json ) {
    if( !$data && !$json ) {
      Log3 $name, 2, "$name: empty answer received";
      return undef;
    } elsif( $data && $data !~ m/^[\[{].*[\]}]$/ ) {
      Log3 $name, 2, "$name: invalid json detected: $data";
      return undef;
    }

    my $queryAfterSet = AttrVal( $name,'queryAfterSet', 1 );

    if( !$json ) {
      $json = eval { from_json($data) } if( !$json );
      Log3 $name, 2, "$name: json error: $@ in $data" if( $@ );
    }
    return undef if( !$json );

    my $type = $param->{type};

    if( ref($json) eq 'ARRAY' )
      {
        HUEBridge_ProcessResponse($hash,$json) if( !$queryAfterSet );

        if( defined($json->[0]->{error}))
          {
            my $error = $json->[0]->{error}->{'description'};

            readingsSingleUpdate($hash, 'lastError', $error, 0 );

            Log3 $name, 3, $error;
          }

        #return ($json->[0]);
      }

    if( $hash == $param->{chash} ) {
      if( !defined($type) ) {
        HUEBridge_Parse($hash,$json->{config});

        if( defined($json->{sensors}) ) {
          my $sensors = $json->{sensors};
          foreach my $id ( keys %{$sensors} ) {
            my $code = $name ."-S". $id;
            my $chash = $modules{HUEDevice}{defptr}{$code};

            if( defined($chash) ) {
              HUEDevice_Parse($chash,$sensors->{$id});
            } else {
              Log3 $name, 4, "$name: message for unknow sensor received: $code";
            }
          }
        }

        if( defined($json->{groups}) ) {
          my $groups = $json->{groups};
          foreach my $id ( keys %{$groups} ) {
            my $code = $name ."-G". $id;
            my $chash = $modules{HUEDevice}{defptr}{$code};

            if( defined($chash) ) {
              HUEDevice_Parse($chash,$groups->{$id});
            } else {
              Log3 $name, 2, "$name: message for unknow group received: $code";
            }
          }
        }

        $type = 'lights';
        $json = $json->{lights};
      }

      if( $type eq 'lights' ) {
        my $lights = $json;
        foreach my $id ( keys %{$lights} ) {
          my $code = $name ."-". $id;
          my $chash = $modules{HUEDevice}{defptr}{$code};

          if( defined($chash) ) {
            HUEDevice_Parse($chash,$lights->{$id});
          } else {
            Log3 $name, 2, "$name: message for unknow device received: $code";
          }
        }

      } elsif( $type =~ m/^config$/ ) {
        HUEBridge_Parse($hash,$json);

      } else {
        Log3 $name, 2, "$name: message for unknow type received: $type";
        Log3 $name, 4, Dumper $json;

      }

    } elsif( $type =~ m/^lights\/(\d*)$/ ) {
      HUEDevice_Parse($param->{chash},$json);

    } elsif( $type =~ m/^groups\/(\d*)$/ ) {
      HUEDevice_Parse($param->{chash},$json);

    } elsif( $type =~ m/^sensors\/(\d*)$/ ) {
      HUEDevice_Parse($param->{chash},$json);

    } elsif( $type =~ m/^lights\/(\d*)\/state$/ ) {
      if( $queryAfterSet ) {
        my $chash = $param->{chash};
        if( $chash->{helper}->{update_timeout} ) {
          RemoveInternalTimer($chash);
          InternalTimer(gettimeofday()+1, "HUEDevice_GetUpdate", $chash, 0);
        } else {
          RemoveInternalTimer($chash);
          HUEDevice_GetUpdate( $chash );
        }
      }

    } elsif( $type =~ m/^groups\/(\d*)\/action$/ ) {
      my $chash = $param->{chash};
      if( $chash->{helper}->{update_timeout} ) {
        RemoveInternalTimer($chash);
        InternalTimer(gettimeofday()+1, "HUEDevice_GetUpdate", $chash, 0);
      } else {
        RemoveInternalTimer($chash);
        HUEDevice_GetUpdate( $chash );
      }

    } else {
      Log3 $name, 2, "$name: message for unknow type received: $type";
      Log3 $name, 4, Dumper $json;

    }
  }
}

#adapted version of the CustomGetFileFromURL subroutine from HttpUtils.pm
sub
HUEBridge_HTTP_Request($$$@)
{
  my ($quiet, $url, $method, $timeout, $data, $noshutdown) = @_;
  $timeout = 4.0 if(!defined($timeout));

  my $displayurl= $quiet ? "<hidden>" : $url;
  if($url !~ /^(http|https):\/\/([^:\/]+)(:\d+)?(\/.*)$/) {
    Log3 undef, 1, "HUEBridge_HTTP_Request $displayurl: malformed or unsupported URL";
    return undef;
  }

  my ($protocol,$host,$port,$path)= ($1,$2,$3,$4);

  if(defined($port)) {
    $port =~ s/^://;
  } else {
    $port = ($protocol eq "https" ? 443: 80);
  }
  $path= '/' unless defined($path);


  my $conn;
  if($protocol eq "https") {
    eval "use IO::Socket::SSL";
    if($@) {
      Log3 undef, 1, $@;
    } else {
      $conn = IO::Socket::SSL->new(PeerAddr=>"$host:$port", Timeout=>$timeout);
    }
  } else {
    $conn = IO::Socket::INET->new(PeerAddr=>"$host:$port", Timeout=>$timeout);
  }
  if(!$conn) {
    Log3 undef, 1, "HUEBridge_HTTP_Request $displayurl: Can't connect to $protocol://$host:$port";
    undef $conn;
    return undef;
  }

  $host =~ s/:.*//;
  #my $hdr = ($data ? "POST" : "GET")." $path HTTP/1.0\r\nHost: $host\r\n";
  my $hdr = $method." $path HTTP/1.0\r\nHost: $host\r\n";
  if(defined($data)) {
    $hdr .= "Content-Length: ".length($data)."\r\n";
    $hdr .= "Content-Type: application/json";
  }
  $hdr .= "\r\n\r\n";
  syswrite $conn, $hdr;
  syswrite $conn, $data if(defined($data));
  shutdown $conn, 1 if(!$noshutdown);

  my ($buf, $ret) = ("", "");
  $conn->timeout($timeout);
  for(;;) {
    my ($rout, $rin) = ('', '');
    vec($rin, $conn->fileno(), 1) = 1;
    my $nfound = select($rout=$rin, undef, undef, $timeout);
    if($nfound <= 0) {
      Log3 undef, 1, "HUEBridge_HTTP_Request $displayurl: Select timeout/error: $!";
      undef $conn;
      return undef;
    }

    my $len = sysread($conn,$buf,65536);
    last if(!defined($len) || $len <= 0);
    $ret .= $buf;
  }

  $ret=~ s/(.*?)\r\n\r\n//s; # Not greedy: switch off the header.
  my @header= split("\r\n", $1);
  my $hostpath= $quiet ? "<hidden>" : $host . $path;
  Log3 undef, 5, "HUEBridge_HTTP_Request $displayurl: Got data, length: ".length($ret);
  if(!length($ret)) {
    Log3 undef, 4, "HUEBridge_HTTP_Request $displayurl: Zero length data, header follows...";
    for (@header) {
        Log3 undef, 4, "HUEBridge_HTTP_Request $displayurl: $_";
    }
  }
  undef $conn;
  if($header[0] =~ /^[^ ]+ ([\d]{3})/ && $1 != 200) {
    my %result = { error => "error: $1" };
    return \%result;
  }
  return $ret;
}

sub
HUEBridge_Attr($$$)
{
  my ($cmd, $name, $attrName, $attrVal) = @_;

  my $orig = $attrVal;
  $attrVal = int($attrVal) if($attrName eq "interval");
  $attrVal = 60 if($attrName eq "interval" && $attrVal < 60 && $attrVal != 0);

  if( $attrName eq "disable" ) {
    my $hash = $defs{$name};
    if( $cmd eq 'set' && $attrVal ne "0" ) {
      readingsSingleUpdate($hash, 'state', 'disabled', 1 );
    } else {
      $attr{$name}{$attrName} = 0;
      readingsSingleUpdate($hash, 'state', 'active', 1 );
      HUEBridge_OpenDev($hash);
    }
  } elsif( $attrName eq "disabledForIntervals" ) {
    my $hash = $defs{$name};
    if( $cmd eq 'set' ) {
      $attr{$name}{$attrName} = $attrVal;
    } else {
      $attr{$name}{$attrName} = "";
    }

    readingsSingleUpdate($hash, 'state', IsDisabled($name)?'disabled':'active', 1 );
    HUEBridge_OpenDev($hash) if( !IsDisabled($name) );
  } elsif( $attrName eq "noshutdown" ) {
    my $hash = $defs{$name};

    if( $cmd eq 'set' ) {
      $hash->{noshutdown} = $attrVal;

    } else {
      if( defined($hash->{manufacturer}) ) {
        $hash->{noshutdown} = ($hash->{manufacturer} =~ /dresden elektronik/i)?1:0;
      } else {
        $hash->{noshutdown} = ($hash->{name} =~ /deCONZ-GW|RaspBee/i)?1:0;
      }
    }

  }

  if( $cmd eq 'set' ) {
    if( $orig ne $attrVal ) {
      $attr{$name}{$attrName} = $attrVal;
      return $attrName ." set to ". $attrVal;
    }
  }

  return;
}

1;

=pod
=item summary    module for the phillips hue bridge
=item summary_DE Modul f&uuml;r die Philips HUE Bridge
=begin html

<a name="HUEBridge"></a>
<h3>HUEBridge</h3>
<ul>
  Module to access the bridge of the phillips hue lighting system.<br><br>

  The actual hue bulbs, living colors or living whites devices are defined as <a href="#HUEDevice">HUEDevice</a> devices.

  <br><br>
  All newly found devices and groups are autocreated at startup and added to the room HUEDevice.

  <br><br>
  Notes:
  <ul>
    <li>This module needs <code>JSON</code>.<br>
        Please install with '<code>cpan install JSON</code>' or your method of choice.</li>
    <li>autocreate only works for the first bridge. devices on other bridges have to be manualy defined.</li>
  </ul>


  <br><br>
  <a name="HUEBridge_Define"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; HUEBridge [&lt;host&gt;] [&lt;interval&gt;]</code><br>
    <br>

    Defines a HUEBridge device with address &lt;host&gt;.<br><br>

    If [&lt;host&gt;] is not given the module will try to autodetect the bridge with the hue portal services.<br><br>

    The bridge status will be updated every &lt;interval&gt; seconds. The default and minimum is 60.<br><br>

    After a new bridge is created the pair button on the bridge has to be pressed.<br><br>

    Examples:
    <ul>
      <code>define bridge HUEBridge 10.0.1.1</code><br>
    </ul>
  </ul><br>

  <a name="HUEBridge_Get"></a>
  <b>Get</b>
  <ul>
    <li>lights<br>
      list the lights known to the bridge.</li>
    <li>groups<br>
      list the groups known to the bridge.</li>
    <li>scenes [detail]<br>
      list the scenes known to the bridge.</li>
    <li>rule &lt;id&gt; <br>
      list the rule with &lt;id&gt;.</li>
    <li>rules [detail] <br>
      list the rules known to the bridge.</li>
    <li>sensors [detail] <br>
      list the sensors known to the bridge.</li>
    <li>whitelist<br>
      list the whitlist of the bridge.</li>
  </ul><br>

  <a name="HUEBridge_Set"></a>
  <b>Set</b>
  <ul>
    <li>autocreate<br>
      Create fhem devices for all bridge devices.</li>
    <li>autodetect<br>
      Initiate the detection of new ZigBee devices. After aproximately one minute any newly detected
      devices can be listed with <code>get <bridge> devices</code> and the corresponding fhem devices
      can be created by <code>set <bridge> autocreate</code>.</li>
    <li>delete &lt;name&gt;|&lt;id&gt;<br>
      Deletes the given device in the bridge and deletes the associated fhem device.</li>
    <li>creategroup &lt;name&gt; &lt;lights&gt;<br>
      Create a group out of &lt;lights&gt; in the bridge.
      The lights are given as a comma sparated list of fhem device names or bridge light numbers.</li>
    <li>deletegroup &lt;name&gt;|&lt;id&gt;<br>
      Deletes the given group in the bridge and deletes the associated fhem device.</li>
    <li>savescene &lt;name&gt; &lt;lights&gt;<br>
      Create a scene from the current state of &lt;lights&gt; in the bridge.
      The lights are given as a comma sparated list of fhem device names or bridge light numbers.</li>
    <li>modifyscene &lt;id&gt; &lt;light&gt; &lt;light-args&gt;<br>
      Modifys the given scene in the bridge.</li>
    <li>scene &lt;id&gt;<br>
      Recalls the scene with the given id.</li>
    <li>createrule &lt;name&gt; &lt;conditions&amp;actions json&gt;<br>
      Creates a new rule in the bridge.</li>
    <li>deleterule &lt;id&gt;<br>
      Deletes the given rule in the bridge.</li>
    <li>createsensor &lt;name&gt; &lt;type&gt; &lt;uniqueid&gt; &lt;swversion&gt; &lt;modelid&gt;<br>
      Creates a new CLIP (IP) sensor in the bridge.</li>
    <li>deletesensor &lt;id&gt;<br>
      Deletes the given sensor in the bridge and deletes the associated fhem device.</li>
    <li>configsensor &lt;id&gt; &lt;json&gt;<br>
      Write sensor config data.</li>
    <li>setsensor &lt;id&gt; &lt;json&gt;<br>
      Write CLIP sensor status data.</li>
    <li>deletewhitelist &lt;key&gt;<br>
      Deletes the given key from the whitelist in the bridge.</li>
    <li>touchlink<br>
      perform touchlink action</li>
    <li>checkforupdate<br>
      perform checkforupdate action</li>
    <li>statusRequest<br>
      Update bridge status.</li>
    <li>swupdate<br>
      Update bridge firmware. This command is only available if a new firmware is
      available (indicated by updatestate with a value of 2. The version and release date is shown in the reading swupdate.<br>
      A notify of the form <code>define HUEUpdate notify bridge:swupdate.* {...}</code>
      can be used to be informed about available firmware updates.<br></li>
  </ul><br>

  <a name="HUEBridge_Attr"></a>
  <b>Attributes</b>
  <ul>
    <li><a href="#disable">disable</a></li>
    <li><a href="#disabledForIntervals">disabledForIntervals</a></li>
    <li>pollDevices<br>
      the bridge will poll all devices instead of each device itself. default is 1.</li>
    <li>queryAfterSet<br>
      the bridge will request the real device state after a set command. default is 1.</li>
    <li>noshutdown<br>
      Some bridge devcies require a different type of connection handling. raspbee/deconz only works if the connection
      is not immediately closed, the phillips hue bridge works better if the connection is immediately closed. This module
      tries to autodetect the bridge device type. the type of connection handling can be seen in the noshutdown internal
      and can be overwritten with the noshutdown attribute.</li>
  </ul><br>
</ul><br>

=end html
=cut
