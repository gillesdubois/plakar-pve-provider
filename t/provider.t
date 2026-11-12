#!/usr/bin/perl
# Test outside PVE: stubs in t/lib, real PVE/BackupProvider/Plugin/Base.pm.
# A child process plays Plakar on the session socket.
#   prove -I t/lib -I src t/provider.t
use strict;
use warnings;

use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use JSON::PP ();
use POSIX ();
use Test::More;

use PVE::Storage;
use PVE::Storage::Custom::PlakarPlugin;

my $class = 'PVE::Storage::Custom::PlakarPlugin';

# --- api() ---------------------------------------------------------------------
for my $case ([16, 16], [11, 11], [10, 16], [18, 16]) {
    $PVE::Storage::APIVER = $case->[0];
    is($class->api(), $case->[1], "api() with APIVER $case->[0]");
}
$PVE::Storage::APIVER = 16;

my $tmp = tempdir(CLEANUP => 1);
$PVE::Storage::Custom::PlakarPlugin::SESSION_ROOT = $tmp;
my @log;
my $log = sub { push @log, "$_[0]: $_[1]" };

sub new_provider {
    return $class->new_backup_provider({}, 'plk', $log);
}

# Simulates Plakar: listens on the session socket, reads the manifest, sends back the reply
# produced by $reply (undef = close without reply). The child's exit code
# tells whether $reply validated the manifest.
sub fake_plakar {
    my ($session, $reply) = @_;
    $ENV{PLAKAR_SESSION} = $session;
    my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "$tmp/$session.sock", Listen => 1)
        or die "socket: $!";
    my $pid = fork() // die "fork: $!";
    if ($pid) {
        close($srv);
        return $pid;
    }
    my $ok = eval {
        my $conn = $srv->accept() or die "accept: $!\n";
        my $m = JSON::PP->new->utf8->decode(scalar <$conn>);
        my $answer = $reply->($m);
        print {$conn} "$answer\n" if defined($answer);
        close($conn);
        1;
    };
    POSIX::_exit($ok ? 0 : 1);
}

sub finish_plakar {
    my ($pid, $session) = @_;
    waitpid($pid, 0);
    my $status = $? >> 8;
    unlink("$tmp/$session.sock");
    return $status;
}

sub touch { open(my $fh, '>', $_[0]) or die "$_[0]: $!"; print $fh ($_[1] // ''); close $fh }

my $volumes = {
    'drive-scsi0' => { size => 1 << 30, 'nbd-path' => '/run/qemu-server/100.backup-access.1/socket', 'bitmap-mode' => 'none' },
    'drive-scsi1' => { size => 2 << 30, 'nbd-path' => '/run/qemu-server/100.backup-access.1/socket', 'bitmap-mode' => 'none' },
};

# --- happy path ---------------------------------------------------------------
{
    my $p = new_provider();
    is($p->backup_get_mechanism(100, 'qemu'), 'nbd', 'nbd mechanism for qemu');
    ok(!defined($p->backup_vm_query_incremental(100, $volumes)), 'no incremental');

    my $pid = fake_plakar('s100', sub {
        my ($m) = @_;
        die "vmid\n" if $m->{vmid} != 100 || $m->{version} != 2;
        die "guest-config\n" if $m->{'guest-config'} ne "cores: 2\ndescription: caf\x{e9}\n";
        die "firewall-config\n" if $m->{'firewall-config'} ne "[OPTIONS]\n";
        die "devices\n" if join(',', sort keys $m->{devices}->%*) ne 'drive-scsi0,drive-scsi1';
        die "nbd-path\n" if $m->{devices}->{'drive-scsi0'}->{'nbd-path'} ne $volumes->{'drive-scsi0'}->{'nbd-path'};
        die "export\n" if exists $m->{devices}->{'drive-scsi1'}->{export};
        return '{"status":"ok"}';
    });

    eval { $p->job_init(1730880000) };
    is($@, '', 'job_init accepts an active Plakar session');
    my $res = $p->backup_init(100, 'qemu', 1730880000);
    like($res->{'archive-name'}, qr{^[A-Za-z0-9_.+-/:]+$}, 'archive-name is valid');

    eval { $p->backup_vm(100, "cores: 2\ndescription: caf\xc3\xa9\n", $volumes, { 'firewall-config' => "[OPTIONS]\n" }) };
    is($@, '', 'backup_vm finishes on Plakar ok reply');
    is(finish_plakar($pid, 's100'), 0, 'fake Plakar validated the manifest');
    ok((grep { $_ eq 'info: Plakar is reading 2 disk(s), 3.0 GiB' } @log), 'progress log shows disk count and size');

    my $stats = $p->backup_cleanup(100, 'qemu', 1, {});
    is($stats->{stats}->{'archive-size'}, 3 << 30, 'archive-size = logical size');
    $p->job_cleanup();
}

# --- failure reported by Plakar-----------------------------------------------
{
    my $p = new_provider();
    my $pid = fake_plakar('s101', sub { '{"status":"error","message":"repository full"}' });
    $p->backup_init(101, 'qemu', 1730880001);
    eval { $p->backup_vm(101, '', $volumes, {}) };
    like($@, qr/Plakar: repository full/, 'Plakar failure propagated');
    finish_plakar($pid, 's101');
}

# --- Plakar dies while reading -----------------------------------------------
{
    my $p = new_provider();
    my $pid = fake_plakar('s102', sub { undef });
    $p->backup_init(102, 'qemu', 1730880002);
    eval { $p->backup_vm(102, '', $volumes, {}) };
    like($@, qr/without replying/, 'connection closed without reply');
    finish_plakar($pid, 's102');
}

# --- unreadable reply ------------------------------------------------------------
{
    my $p = new_provider();
    my $pid = fake_plakar('s103', sub { 'not json' });
    $p->backup_init(103, 'qemu', 1730880003);
    eval { $p->backup_vm(103, '', $volumes, {}) };
    like($@, qr/unreadable reply from Plakar: not json/, 'non-JSON reply rejected and shown');
    finish_plakar($pid, 's103');
}

# --- Plakar closes before reading the manifest ----------------------------------
{
    my $p = new_provider();
    $ENV{PLAKAR_SESSION} = 's104';
    my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "$tmp/s104.sock", Listen => 1)
        or die "socket: $!";
    my $pid = fork() // die "fork: $!";
    if (!$pid) { close($srv->accept()); POSIX::_exit(0) }
    close($srv);
    $p->backup_init(104, 'qemu', 1730880004);
    # large guest config so the write hits the closed socket instead of the buffer
    eval { $p->backup_vm(104, 'x' x (4 << 20), $volumes, {}) };
    like($@, qr/cannot send manifest|without replying/, 'closed socket gives an error, not SIGPIPE');
    finish_plakar($pid, 's104');
}

# --- vzdump started without Plakar------------------------------------------------
{
    my $p = new_provider();
    delete $ENV{PLAKAR_SESSION};
    eval { $p->job_init(1730880004) };
    like($@, qr/PLAKAR_SESSION missing/, 'no PLAKAR_SESSION, immediate failure');

    $ENV{PLAKAR_SESSION} = '../../etc/x';
    eval { $p->job_init(1730880004) };
    like($@, qr/invalid PLAKAR_SESSION/, 'session outside directory rejected');

    $ENV{PLAKAR_SESSION} = 'missing';
    eval { $p->job_init(1730880004) };
    like($@, qr/not listening/, 'missing socket, immediate failure');
}

# --- rejected inputs ------------------------------------------------------------
{
    my $p = new_provider();
    $p->backup_init(105, 'qemu', 1730880005);
    eval { $p->backup_vm(105, '', { '../evil' => { size => 1, 'nbd-path' => '/x' } }, {}) };
    like($@, qr/unexpected device name/, 'invalid device rejected');
    eval { $p->backup_vm(105, '', { 'drive-scsi0' => { 'nbd-path' => '/x' } }, {}) };
    like($@, qr/drive-scsi0: invalid size/, 'missing disk size rejected');
    eval { $p->backup_get_mechanism(105, 'lxc') };
    like($@, qr/LXC.*vzdump --stdout/, 'LXC backup rejected with a backup hint');
    eval { $p->restore_get_mechanism('105/qemu-1') };
    like($@, qr/plakar restore/, 'restore redirected to Plakar');
}

# --- restore --------------------------------------------------------------------
{
    # Fake sysfs: nbd0 already busy; fake qemu-nbd that logs and rejects nbd1 if 'busy1'.
    my $sys = "$tmp/sys";
    make_path("$sys/nbd$_") for 0 .. 2;
    touch("$sys/nbd0/pid", 1);
    my $nbdlog = "$tmp/qemu-nbd.log";
    touch("$tmp/qemu-nbd", "#!/bin/sh\ncase \"\$*\" in *connect\\ /dev/nbd1*) [ -e $tmp/busy1 ] && exit 1;; esac\n"
        . "echo \"\$*\" >> $nbdlog\n");
    chmod(0755, "$tmp/qemu-nbd");
    local $PVE::BackupProvider::Plugin::Plakar::QEMU_NBD = "$tmp/qemu-nbd";
    local $PVE::BackupProvider::Plugin::Plakar::SYS_BLOCK = $sys;

    my $p = $class->new_backup_provider({}, 'plk', $log);
    my $vol = '100/qemu-1730880000';
    my $s = "$tmp/plk/restore/100-qemu-1730880000";

    # What Plakar prepares before calling qmrestore
    make_path($s, { mode => 0700 });
    touch("$s/manifest.json", '{"version":1,"devices":{"drive-scsi0":{"size":1073741824}}}');
    touch("$s/guest.conf", "cores: 2\nscsi0: local-lvm:vm-100-disk-0,size=1G\n");
    my $srv = IO::Socket::UNIX->new(Type => SOCK_STREAM(), Local => "$s/drive-scsi0.sock", Listen => 1)
        or die "socket: $!";

    is_deeply([$p->restore_get_mechanism($vol)], ['qemu-img', 'qemu'], 'restore: qemu-img mechanism');
    is_deeply($p->restore_vm_init($vol), { 'drive-scsi0' => { size => 1 << 30 } }, 'restore: sizes');
    like($p->archive_get_guest_config($vol), qr/^cores: 2/, 'restore: guest.conf');
    ok(!defined($p->archive_get_firewall_config($vol)), 'restore: no firewall');

    is_deeply($p->restore_vm_volume_init($vol, 'drive-scsi0', {}), { 'qemu-img-path' => '/dev/nbd1' },
        'restore: nbd0 busy -> nbd1');
    $p->restore_vm_volume_cleanup($vol, 'drive-scsi0', {});

    touch("$tmp/busy1");
    is($p->restore_vm_volume_init($vol, 'drive-scsi0', {})->{'qemu-img-path'}, '/dev/nbd2',
        'restore: nbd1 taken meanwhile -> nbd2');
    $p->restore_vm_cleanup($vol); # must disconnect nbd2 without restore_vm_volume_cleanup

    my $uri = "nbd+unix:///drive-scsi0?socket=$s/drive-scsi0.sock";
    is(do { open(my $fh, '<', $nbdlog) or die; local $/; <$fh> },
        "--connect /dev/nbd1 --read-only --format raw $uri\n--disconnect /dev/nbd1\n"
        . "--connect /dev/nbd2 --read-only --format raw $uri\n--disconnect /dev/nbd2\n",
        'restore: qemu-nbd calls');
    ok(!-e $s, 'restore: session removed');

    eval { $p->restore_vm_init($vol) };
    like($@, qr/plakar restore/, 'restore without a Plakar-prepared session rejected');
    eval { $p->restore_get_mechanism('100/lxc-1730880000') };
    like($@, qr/LXC.*plakar restore/, 'LXC restore rejected with a restore hint');

    make_path($s);
    touch("$s/manifest.json", '{"version":1}');
    eval { $p->restore_vm_init($vol) };
    like($@, qr/invalid restore manifest/, 'manifest without devices rejected');
    touch("$s/manifest.json", '{"version":1,"devices":{}}');
    eval { $p->restore_vm_init($vol) };
    like($@, qr/invalid restore manifest/, 'manifest with no disks rejected');
}

is_deeply([$class->parse_volname('100/qemu-1730880000')], ['backup', '100/qemu-1730880000', 100], 'parse_volname');

done_testing();
