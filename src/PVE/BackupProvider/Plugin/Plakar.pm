package PVE::BackupProvider::Plugin::Plakar;

# SPDX-License-Identifier: ISC

use strict;
use warnings;

use File::Path qw(remove_tree);
use IO::Socket::UNIX;
use JSON qw(from_json to_json);
use Socket qw(SOCK_STREAM);

use PVE::Tools qw(file_get_contents run_command);

use base qw(PVE::BackupProvider::Plugin::Base);

our $QEMU_NBD = '/usr/bin/qemu-nbd'; 
our $SYS_BLOCK = '/sys/block';

my sub log_msg {
    my ($self, $level, $message) = @_;
    $self->{'log-function'}->($level, $message);
}

my $NO_LXC_BACKUP = "LXC container backup is not supported - Plakar backs up containers"
    . " with vzdump --stdout";
my $NO_LXC_RESTORE = "LXC container restore is not supported - use 'plakar restore'";

my sub unsupported {
    my ($message) = @_;
    die "Plakar provider: $message\n";
}

my sub check_device_name {
    my ($device) = @_;
    die "unexpected device name '$device'\n" if $device !~ m/^[A-Za-z0-9_.-]+$/ || $device =~ m/^\./;
    return $device;
}

my sub session_socket {
    my ($self) = @_;

    my $raw = $ENV{PLAKAR_SESSION}
        // die "PLAKAR_SESSION missing - the backup must be started by Plakar\n";
    my ($session) = $raw =~ m/^([A-Za-z0-9_-]+)$/
        or die "invalid PLAKAR_SESSION '$raw'\n";

    return $self->{'storage-plugin'}->socket_dir($self->{scfg}) . "/$session.sock";
}

sub new {
    my ($class, $storage_plugin, $scfg, $storeid, $log_function) = @_;

    return bless {
        'storage-plugin' => $storage_plugin,
        scfg => $scfg,
        storeid => $storeid,
        'log-function' => $log_function,
    }, $class;
}

sub provider_name {
    my ($self) = @_;
    return 'Plakar';
}

sub job_init {
    my ($self, $start_time) = @_;

    my $socket = session_socket($self);
    die "Plakar is not listening on '$socket'\n" if !-S $socket;
    return;
}

sub job_cleanup {
    my ($self) = @_;
    return;
}

sub backup_init {
    my ($self, $vmid, $vmtype, $start_time) = @_;

    my $archive = "${vmid}/${vmtype}-${start_time}";
    $self->{backup}->{$vmid} = { archive => $archive, size => 0 };

    return { 'archive-name' => $archive };
}

sub backup_get_mechanism {
    my ($self, $vmid, $vmtype) = @_;

    return 'nbd' if $vmtype eq 'qemu';
    unsupported($NO_LXC_BACKUP);
}

sub backup_vm_query_incremental {
    my ($self, $vmid, $volumes) = @_;
    return;
}

sub backup_vm {
    my ($self, $vmid, $guest_config, $volumes, $info) = @_;

    my $state = $self->{backup}->{$vmid} or die "backup_vm called without backup_init for $vmid\n";

    my $devices = {};
    for my $device (sort keys $volumes->%*) {
        check_device_name($device);
        my $volume = $volumes->{$device};
        die "$device: no 'nbd-path' (mechanism must be 'nbd')\n" if !$volume->{'nbd-path'};
        die "$device: invalid size\n" if ($volume->{size} // '') !~ m/^\d+$/;

        $devices->{$device} = {
            size => $volume->{size} + 0,
            'nbd-path' => $volume->{'nbd-path'},
        };
        $state->{size} += $volume->{size};
    }

    my $firewall_config = $info->{'firewall-config'};
    utf8::decode($guest_config);
    utf8::decode($firewall_config) if defined($firewall_config);

    my $manifest = {
        version => 2,
        vmid => $vmid + 0,
        archive => $state->{archive},
        'bandwidth-limit' => ($info->{'bandwidth-limit'} // 0) + 0,
        'guest-config' => $guest_config,
        'firewall-config' => $firewall_config,
        devices => $devices,
    };

    my $path = session_socket($self);
    local $SIG{PIPE} = 'IGNORE';
    my $sock = IO::Socket::UNIX->new(Type => SOCK_STREAM, Peer => $path)
        or die "cannot connect to Plakar on '$path' - $!\n";

    print {$sock} to_json($manifest, { utf8 => 1, canonical => 1 }), "\n"
        or die "cannot send manifest to Plakar - $!\n";
    log_msg($self, 'info', sprintf("Plakar is reading %d disk(s), %.1f GiB",
        scalar(keys $devices->%*), $state->{size} / 2**30));

    my $reply = <$sock>;
    close($sock);

    die "Plakar closed the connection without replying\n" if !defined($reply);
    my $res = eval { from_json($reply, { utf8 => 1 }) };
    die "unreadable reply from Plakar: " . substr($reply, 0, 200) . "\n" if ref($res) ne 'HASH';
    die "Plakar: " . ($res->{message} // 'unknown error') . "\n" if ($res->{status} // '') ne 'ok';

    log_msg($self, 'info', "Plakar has read all disks");
    return;
}

sub backup_cleanup {
    my ($self, $vmid, $vmtype, $success, $info) = @_;

    my $state = delete $self->{backup}->{$vmid} // {};
    return $success ? { stats => { 'archive-size' => $state->{size} // 0 } } : undef;
}

sub backup_handle_log_file {
    my ($self, $vmid, $filename) = @_;
    return;
}

sub backup_container_prepare {
    my ($self, $vmid, $info) = @_;
    unsupported($NO_LXC_BACKUP);
}

sub backup_container {
    my ($self, $vmid, $guest_config, $exclude_patterns, $info) = @_;
    unsupported($NO_LXC_BACKUP);
}

my sub restore_session {
    my ($self, $volname) = @_;

    my (undef, $name, undef) = $self->{'storage-plugin'}->parse_volname($volname);
    $name =~ tr!/!-!;
    my $root = $self->{'storage-plugin'}->session_root($self->{scfg}, $self->{storeid});
    my $session = "$root/restore/$name";
    die "no restore session '$session' - restores are started with"
        . " 'plakar restore', which prepares the session then calls qmrestore\n"
        if !-e "$session/manifest.json";

    return $session;
}

my sub read_manifest {
    my ($session) = @_;
    my $file = "$session/manifest.json";
    my $manifest = eval { from_json(file_get_contents($file, 1024 * 1024)) };
    die "invalid restore manifest '$file'\n"
        if ref($manifest->{devices}) ne 'HASH' || !$manifest->{devices}->%*;
    return $manifest;
}

my sub nbd_disconnect {
    my ($self, $dev) = @_;
    eval { run_command([$QEMU_NBD, '--disconnect', $dev], outfunc => sub { }) };
    log_msg($self, 'warn', "cannot disconnect $dev - $@") if $@;
}

sub restore_get_mechanism {
    my ($self, $volname) = @_;

    unsupported($NO_LXC_RESTORE) if $volname =~ m!/lxc-!;
    restore_session($self, $volname);
    return ('qemu-img', 'qemu');
}

sub restore_vm_init {
    my ($self, $volname) = @_;

    my $manifest = read_manifest(restore_session($self, $volname));
    my $devinfo = {};
    for my $device (keys $manifest->{devices}->%*) {
        my $size = $manifest->{devices}->{$device}->{size};
        die "$device: invalid size in manifest\n" if !defined($size) || $size !~ m/^\d+$/;
        $devinfo->{ check_device_name($device) } = { size => $size + 0 };
    }

    return $devinfo;
}

sub archive_get_guest_config {
    my ($self, $volname) = @_;
    return file_get_contents(restore_session($self, $volname) . "/guest.conf");
}

sub archive_get_firewall_config {
    my ($self, $volname) = @_;
    my $file = restore_session($self, $volname) . "/firewall.conf";
    return -e $file ? file_get_contents($file) : undef;
}

sub restore_vm_volume_init {
    my ($self, $volname, $device_name, $info) = @_;

    my $session = restore_session($self, $volname);
    check_device_name($device_name);
    my $socket = "$session/$device_name.sock";
    die "$device_name: Plakar is not serving '$socket'\n" if !-S $socket;

    run_command(['modprobe', 'nbd']) if !-e "$SYS_BLOCK/nbd0";

    my $uri = "nbd+unix:///$device_name?socket=$socket";
    my $last_err = 'no nbd device';
    for my $sys (sort { ($a =~ /(\d+)$/)[0] <=> ($b =~ /(\d+)$/)[0] } glob("$SYS_BLOCK/nbd*")) {
        next if -e "$sys/pid";
        my ($nbd) = $sys =~ m!/(nbd\d+)$! or next;
        my $dev = "/dev/$nbd";
        eval {
            run_command(
                [$QEMU_NBD, '--connect', $dev, '--read-only', '--format', 'raw', $uri],
                outfunc => sub { },
            );
        };
        if ($last_err = $@) {
            chomp $last_err;
            next;
        }
        $self->{restore}->{$volname}->{$device_name} = $dev;
        log_msg($self, 'info', "$device_name: reading from Plakar via $dev");
        return { 'qemu-img-path' => $dev };
    }

    die "$device_name: cannot attach Plakar export to a /dev/nbdX - $last_err\n";
}

sub restore_vm_volume_cleanup {
    my ($self, $volname, $device_name, $info) = @_;

    my $dev = delete $self->{restore}->{$volname}->{$device_name};
    nbd_disconnect($self, $dev) if $dev;
    return;
}

sub restore_vm_cleanup {
    my ($self, $volname) = @_;

    my $devs = delete($self->{restore}->{$volname}) // {};
    nbd_disconnect($self, $_) for values $devs->%*;

    my $session = eval { restore_session($self, $volname) };
    remove_tree($session) if $session;
    return;
}

sub restore_container_init { unsupported($NO_LXC_RESTORE) }
sub restore_container_cleanup { return }

1;
