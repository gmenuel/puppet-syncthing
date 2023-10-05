define syncthing::instance
(
  Stdlib::Absolutepath $home_path,

  String $ensure            = 'present',

  # Download and use a separate syncthing binary instead of the package binary
  Boolean $binary            = false,
  # Path to the binary
  Variant[Boolean, Stdlib::Absolutepath] $binary_path       = false,
  # Version to download. Since syncthing automatically upgrades itself, no
  # binary will be downloaded if it already exists; only initially. This instance
  # will then rely on auto-upgrading or user-upgrading.
  String $binary_version    = 'latest',

  Boolean $create_home_path  = $::syncthing::create_home_path,

  String $daemon_uid             = $::syncthing::daemon_uid,
  String $daemon_gid             = $::syncthing::daemon_gid,
  String $daemon_umask           = $::syncthing::daemon_umask,
  Optional[Integer] $daemon_nice = $::syncthing::daemon_nice,
  Optional[String] $daemon_debug = $::syncthing::daemon_debug,

  Boolean $gui                        = $::syncthing::gui,
  Boolean $gui_tls                    = $::syncthing::gui_tls,
  String $gui_address                 = $::syncthing::gui_address,
  String $gui_port                    = $::syncthing::gui_port,
  Optional[String] $gui_apikey        = $::syncthing::gui_apikey,
  Optional[String] $gui_user          = $::syncthing::gui_user,
  Optional[String] $gui_password      = $::syncthing::gui_password,
  Optional[String] $gui_password_salt = $::syncthing::gui_password_salt,
  Hash $gui_options                   = $::syncthing::gui_options,

  Hash $options           = $::syncthing::instance_options,

  Hash $devices           = {},
  Hash $folders           = {},
)
{
  if ! defined(Class['syncthing']) {
    fail('You must include the syncthing base class before using any syncthing defined resources')
  }

#  if $gui_password and !$gui_password_salt {
#    fail("When specifying a GUI password, a salt must be supplied (or else your instance will restart on every puppet run.")
#  }

  $instance_config_path     = "${syncthing::instancespath}/${name}.conf"
  $instance_config_xml_path = "${home_path}/config.xml"

  if $ensure == 'present' {
    if $binary {
      ::syncthing::install_binary { "syncthing instance ${name} binary":
        path    => $binary_path,
        version => $binary_version,
        user    => $daemon_uid,
        group   => $daemon_gid,
      }

      $daemon = "${binary_path}/syncthing"

      if $create_home_path {
        ::Syncthing::Install_binary["syncthing instance ${name} binary"] -> Exec["create syncthing instance ${home_path}"]
      }

      ::syncthing::instance_service { $name:
        daemon       => $daemon,
        home_path    => $home_path,
        configpath   => $instance_config_path,
        daemon_uid   => $daemon_uid,
        daemon_gid   => $daemon_gid,
        daemon_umask => $daemon_umask,
        daemon_nice  => $daemon_nice,
        daemon_debug => $daemon_debug,
        tag          => [
          'syncthing_binary_instance_service',
        ],
      }
    } else {
      $daemon = $::syncthing::binpath

      if $create_home_path {
        Class['::syncthing::install_package'] -> Exec["create syncthing instance ${home_path}"]
      }

      ::syncthing::instance_service { $name:
        daemon       => $daemon,
        home_path    => $home_path,
        configpath   => $instance_config_path,
        daemon_uid   => $daemon_uid,
        daemon_gid   => $daemon_gid,
        daemon_umask => $daemon_umask,
        daemon_nice  => $daemon_nice,
        daemon_debug => $daemon_debug,
        tag          => [
          'syncthing_binary_instance_service',
        ],
      }
    }

    if $create_home_path {
      exec { "create syncthing instance ${name} home path":
        command  => "sudo -u ${daemon_uid} mkdir -p \"${home_path}\"",
        path     => $::path,
        creates  => $home_path,
        provider => shell,

        before   => [
          Exec["create syncthing instance ${home_path}"],
          ::Syncthing::Instance_service[$name],
        ]
      }

      exec { "create syncthing instance ${home_path}":
        path        => $::path,
        command     => "${syncthing::binpath} -generate \"${home_path}\"",
        environment => [ 'STNODEFAULTFOLDER=1', 'HOME=$HOME' ],
        user        => $daemon_uid,
        group       => $daemon_gid,
        creates     => $instance_config_xml_path,
        provider    => shell,

        before      => [
          Exec["start syncthing instance ${name}"],
        ],
        notify      => [
          Exec["restart syncthing instance ${name}"],
        ],
      }
    }

    if $gui_password_salt {
      $gui_password_hashed = syncthing_bcrypt($gui_password, $gui_password_salt)
    } else {
      $gui_password_hashed = undef
    }

    $changes = parseyaml( template('syncthing/config-changes.yaml.erb') )
    #notify { 'debug': message => $changes }

    augeas { "syncthing ${name} basic config":
      incl    => $instance_config_xml_path,
      lens    => 'Xml.lns',
      context => "/files${instance_config_xml_path}/configuration",
      changes => $changes,
      require => [
        Exec["create syncthing instance ${home_path}"],
      ],
      before  => [
        Exec["start syncthing instance ${name}"],
      ],
      notify  => [
        Exec["restart syncthing instance ${name}"],
      ],
    }

    if ('globalAnnounceServer' in $options) {
      $changes_announce_server = parseyaml( template('syncthing/config_announce_server-changes.yaml.erb') )
      augeas {"add custom globalAnnounceServer for instance ${name}":
        incl    => $instance_config_xml_path,
        lens    => 'Xml.lns',
        context => "/files${instance_config_xml_path}/configuration",
        changes => $changes_announce_server,
        notify  => Exec["restart syncthing instance ${name}"],
        require => Augeas["syncthing ${name} basic config"],
        onlyif  => 'match options/globalAnnounceServer size == 1',
        before  => [
          Exec["start syncthing instance ${name}"],
        ],
      }
    }

    each($devices) |$device_name, $device_parameters| {
      create_resources(::syncthing::device, { "instance ${name} device ${device_name}" => $device_parameters }, {
        home_path     => $home_path,
        instance_name => $name,
        device_name   => $device_name,

        before        => [
          Exec["start syncthing instance ${name}"],
        ],
        require       => [
          Augeas["syncthing ${name} basic config"],
        ],
      })
    }

    each($folders) |$folder_name, $folder_parameters| {
      create_resources(::syncthing::folder, { "instance ${name} folder ${folder_name}" => $folder_parameters }, {
        home_path     => $home_path,
        instance_name => $name,
        id            => $folder_name,
        label         => $folder_name,

        before        => [
          Exec["start syncthing instance ${name}"],
        ],
        require       => [
          Augeas["syncthing ${name} basic config"],
        ],
      })
    }
  } else {
    ::syncthing::instance_service { $name:
      ensure     => absent,
      daemon_uid => $daemon_uid,
      tag        => [
        'syncthing_binary_instance_service',
      ],
    }
  }
}
