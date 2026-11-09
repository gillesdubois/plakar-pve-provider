package PVE::Storage::Custom::PlakarPlugin;

# SPDX-License-Identifier: ISC

use strict;
use warnings;

use PVE::Storage;
use PVE::Storage::Plugin;

use PVE::BackupProvider::Plugin::Plakar;

use base qw(PVE::Storage::Plugin);

sub api {
    my $min = 11;
    my $max = 16;

    my $current = PVE::Storage::APIVER;
    return $current if $current >= $min && $current <= $max;
    return $max;
}

sub type {
    return 'plakar';
}

sub plugindata {
    return {
        content => [{ backup => 1, none => 1 }, { backup => 1 }],
        features => { 'backup-provider' => 1 },
        'sensitive-properties' => {},
    };
}

sub properties {
    return {
        'plakar-session-root' => {
            description => "Directory (tmpfs) holding the rendezvous sockets and sessions shared with Plakar.",
            type => 'string',
            format => 'pve-storage-path',
            default => '/run/plakar',
        },
    };
}

sub options {
    return {
        'plakar-session-root' => { optional => 1 },
        disable => { optional => 1 },
        nodes => { optional => 1 },
    };
}

sub socket_dir {
    my ($class, $scfg) = @_;
    return $scfg->{'plakar-session-root'} // properties()->{'plakar-session-root'}->{default};
}

sub session_root {
    my ($class, $scfg, $storeid) = @_;
    return $class->socket_dir($scfg) . "/$storeid";
}

sub new_backup_provider {
    my ($class, $scfg, $storeid, $log_function) = @_;

    return PVE::BackupProvider::Plugin::Plakar->new($class, $scfg, $storeid, $log_function);
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;
    return 1;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;
    return (0, 0, 0, 1);
}

sub list_volumes {
    my ($class, $storeid, $scfg, $vmid, $content_types) = @_;
    return [];
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;
    return [];
}

sub prune_backups {
    my ($class, $scfg, $storeid, $keep, $vmid, $type, $dryrun, $logfunc) = @_;
    $logfunc->('info', "retention is managed by Plakar - nothing to prune on the Proxmox side") if $logfunc;
    return [];
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m!^((\d+)/(?:qemu|lxc)-\d+)$!) {
        return ('backup', $1, $2);
    }
    die "invalid volume name '$volname'\n";
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    die "plakar storage does not expose a local path\n";
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache, $hints) = @_;
    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    return 1;
}

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;
    return;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;
    return 0;
}

sub alloc_image { die "plakar storage does not hold images\n" }
sub free_image { die "deletion must be done from Plakar\n" }
sub create_base { die "not supported on plakar storage\n" }
sub clone_image { die "not supported on plakar storage\n" }
sub volume_size_info { die "size is only available from Plakar\n" }
sub volume_resize { die "not supported on plakar storage\n" }
sub volume_snapshot { die "not supported on plakar storage\n" }
sub volume_snapshot_rollback { die "not supported on plakar storage\n" }
sub volume_snapshot_delete { die "not supported on plakar storage\n" }
sub update_volume_attribute { die "not supported on plakar storage\n" }

1;
