package MGA::Git;

use strict;
use Git::Repository;
use YAML qw(LoadFile DumpFile);
use Template;
use File::Slurp;
use File::Basename;
use Net::LDAP;
use feature 'state';
use Data::Dump qw/dd/;

our $config_file = '/usr/share/mgagit/config';
our $config = LoadFile($ENV{MGAGIT_CONF} || $config_file);
our $etc_config_file = '/etc/mgagit.conf';
my $etc_config = LoadFile($etc_config_file);
@{$config}{keys %$etc_config} = values %$etc_config;

sub load_gitrepos_dir {
    my ($r, $infos) = @_;
    if (!$infos->{include_dir}) {
        my ($dir) = fileparse($infos->{git_url});
        $dir =~ s/\.git$//;
        $infos->{include_dir} = "$config->{repodef_dir}/$dir";
        if (-d $infos->{include_dir}) {
            my $repo = Git::Repository->new(work_tree => $infos->{include_dir});
            $repo->run('pull');
        } else {
            Git::Repository->run(clone => $infos->{git_url}, $infos->{include_dir});
        }
    }
    opendir(my $dh, $infos->{include_dir})
        || die "Error opening $infos->{include_dir}: $!";
    while (my $file = readdir($dh)) {
        if (-d "$infos->{include_dir}/$file") {
            next if $file =~ m/^\./;
            my %i = %$infos;
            $i{prefix} .= '/' . $file if $i{prefix};
            $i{include_dir} .= '/' . $file;
            load_gitrepos_dir($r, \%i);
        } elsif ($file =~ m/(.+)\.repo$/ && $infos->{prefix}) {
            my $bname = $1;
            my $name = "$infos->{prefix}/$bname";
            $r->{repos}{$name} = LoadFile("$infos->{include_dir}/$file");
            $r->{repos}{$name}{name} = $bname;
            $r->{repos}{$name}{origin} = $infos->{origin};
        } elsif ($file =~ m/(.+)\.group$/ && exists $infos->{group_prefix}) {
            my $bname = $1;
            my $name = $infos->{group_prefix} . $bname;
            if (exists $r->{groups}{$name}) {
                print STDERR "Warning: Redifinition of $name group.\n";
                next;
            }
            $r->{groups}{$name} = [ read_file("$infos->{include_dir}/$file") ];
            chomp @{$r->{groups}{$name}};
        }
    }
    closedir $dh;
}

sub load_gitrepos {
    my ($r) = @_;
    $r->{repos} = {};
    foreach my $repodef (@{$config->{repos_config}}) {
        $repodef->{origin} = $repodef->{prefix};
        if ($repodef->{include_dir} || $repodef->{git_url}) {
            load_gitrepos_dir($r, $repodef);
        }
        foreach my $repo ($repodef->{repos} ? @{$repodef->{repos}} : ()) {
            my $name = "$repodef->{prefix}/$repo->{name}";
            $repo->{origin} = $repodef->{origin};
            $r->{repos}{$name} = $repo;
        }
    }
}

sub origin_config {
    my ($r, $reponame, $confname) = @_;
    my $origin = $r->{repos}{$reponame}{origin};
    foreach my $repodef (@{$config->{repos_config}}) {
        next unless ($repodef->{prefix} eq $origin);
        return $repodef->{$confname} if defined $repodef->{$confname};
        last;
    }
    return $config->{$confname};
}

sub repo_config {
    my ($r, $reponame, $confname) = @_;
    my $res = $r->{repos}{$reponame}{$confname};
    return defined $res ? $res : origin_config($r, $reponame, $confname);
}

sub get_ldap {
    state $ldap;
    return $ldap if $ldap;
    my $bindpw = read_file($config->{bindpwfile}) 
        or die "Error reading $config->{bindpwfile}";
    chomp $bindpw;
    $ldap = Net::LDAP->new($config->{ldapserver}) or die "$@";
    my $m = $ldap->start_tls(verify => 'none');
    die $m->error if $m->is_error;
    $m = $ldap->bind($config->{binddn}, password => $bindpw);
    die $m->error if $m->is_error;
    return $ldap;
}

sub re {
    my ($re, $txt) = @_;
    my $rr = qr/$config->{$re}/;
    return $txt =~ m/$rr/ ? $1 : undef;
}

sub load_groups {
    my ($r) = @_;
    return unless $config->{use_ldap} eq 'yes';
    my $ldap = get_ldap;
    my $m = $ldap->search(
        base => $config->{groupbase},
        filter => $config->{groupfilter},
    );
    my $res = $m->as_struct;
    @{$r->{groups}}{map { re('group_re', $_) } keys %$res} =
        map { [ map { re('uid_username_re', $_) || () } @{$_->{member}} ] }
        values %$res;
}

sub load_users {
    my ($r) = @_;
    return unless $config->{use_ldap} eq 'yes';
    my $ldap = get_ldap;
    my $m = $ldap->search(
        base => $config->{userbase},
        filter => $config->{userfilter},
    );
    my @users = grep { $_->{sshpublickey} } values %{$m->as_struct};
    my %keepinfos = map { $_ => 1 } @{$config->{ldap_users_infos}};
    foreach my $user (@users) {
        my $uid = $user->{uid}[0];
        my %u = map { $keepinfos{$_} ? ($_ => $user->{$_}) : () } keys %$user;
        $r->{users}{$uid} = \%u;
    }
}

sub get_tmpl {
    my ($name, $ext) = @_;
    state %tmpl;
    return $tmpl{"$name.$ext"} if $tmpl{"$name.$ext"};
    my $tmpl_file = "$config->{tmpl_dir}/$name.$ext";
    $tmpl{"$name.$ext"} = read_file($tmpl_file);
    die "Error reading $tmpl_file" unless $tmpl{"$name.$ext"};
    return $tmpl{"$name.$ext"};
}

sub process_tmpl {
    my ($tmplname, $ext, $vars) = @_;
    my $tt = Template->new;
    my $tmpl = get_tmpl($tmplname, $ext);
    my $c;
    $tt->process(\$tmpl, $vars, \$c);
    return $c;
}

sub gitolite_repo_config {
    my ($r, $repo) = @_;
    my $vars = {
        r      => $r,
        repo   => $repo,
        config => $config,
        repo_conf   => sub { repo_config($r, $repo, @_) },
        origin_conf => sub { origin_config($r, $repo, @_) },
    };
    return process_tmpl(origin_config($r, $repo, 'gl_template'), 'gl', $vars);
}

sub gitolite_group_config {
    my ($r, $group) = @_;
    my $vars = {
        r      => $r,
        group  => $group,
        config => $config,
    };
    return process_tmpl('group', 'gl', $vars);
}

sub gitolite_config {
    my ($r) = @_;
    my (@repos, @groups);
    @repos = map { gitolite_repo_config($r, $_) } sort keys %{$r->{repos}};
    @groups = map { gitolite_group_config($r, $_) } sort keys %{$r->{groups}};
    return join("\n", @groups, @repos);
}

sub update_gitolite_keydir {
    my ($r) = @_;
    opendir(my $dh, $config->{pubkey_dir})
        || die "Error opening $config->{include_dir}: $!";
    my @files = grep { ! m/^\./ } readdir($dh);
    closedir $dh;
    my %users_old;
    @users_old{@files} = map { read_file("$config->{pubkey_dir}/$_") } @files;
    my %users_new;
    foreach my $u (keys %{$r->{users}}) {
        my $i = 0;
        foreach my $key (@{$r->{users}{$u}{sshpublickey}}) {
            next unless $key;
            $users_new{"$u\@$i.pub"} = $key;
            $i++;
        }
    }
    foreach my $file (keys %users_old) {
        chomp $users_old{$file};
        if (!$users_new{$file}) {
            print "Removing $file\n";
            unlink "$config->{pubkey_dir}/$file";
            $r->{keydir_changed} = 1;
        }
    }
    foreach my $file (keys %users_new) {
        chomp $users_new{$file};
        if (!$users_old{$file} || $users_old{$file} ne $users_new{$file}) {
            print "Writing $file\n";
            write_file("$config->{pubkey_dir}/$file", $users_new{$file});
            $r->{keydir_changed} = 1;
        }
    }
}

sub dumpdb {
    my ($r) = @_;
    DumpFile($config->{www_dir} . '/repos.yaml', $r);
}

sub update_gitolite_config {
    my ($r) = @_;
    my $oldconf = -f $config->{gitolite_config} 
                ? read_file($config->{gitolite_config}) : '';
    my $newconf = gitolite_config($r);
    if ($oldconf ne $newconf) {
        write_file($config->{gitolite_config}, $newconf);
        $r->{glconf_changed} = 1;
    }
}

sub run_gitolite {
    my ($r) = @_;
    if ($config->{run_gitolite} && $config->{run_gitolite} eq 'yes'
        && ($r->{keydir_changed} || $r->{glconf_changed})) {
        system('gitolite', 'compile');
        system('gitolite', 'setup', '--hooks-only');
        system('gitolite', 'trigger', 'POST_COMPILE');
    }
}

1;
