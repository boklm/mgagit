package MGA::Git;

use strict;
use YAML qw(LoadFile);
use Template;
use File::Slurp;
use Net::LDAP;
use feature 'state';
use Data::Dump qw/dd/;

our $config_file = '/usr/share/mgagit/config';
our $config = LoadFile($ENV{MGAGIT_CONF} || $config_file);
our $etc_config_file = '/etc/mgagit.conf';
my $etc_config = LoadFile($etc_config_file);
@{$config}{keys %$etc_config} = values %$etc_config;

sub load_gitrepos_dir {
    my ($repos, $infos) = @_;
    opendir(my $dh, $infos->{include_dir})
        || die "Error opening $infos->{include_dir}: $!";
    while (my $file = readdir($dh)) {
        if (-d "$infos->{include_dir}/$file") {
            next if $file =~ m/^\./;
            my %i = %$infos;
            $i{prefix} .= '/' . $file;
            $i{include_dir} .= '/' . $file;
            load_gitrepos_dir($repos, \%i);
        } elsif ($file =~ m/(.+)\.repo$/) {
            my $bname = $1;
            my $name = "$infos->{prefix}/$bname";
            $repos->{$name} = LoadFile("$infos->{include_dir}/$file");
            $repos->{$name}{name} = $bname;
            @{$repos->{$name}}{keys %$infos} = values %$infos;
        }
    }
    closedir $dh;
}

sub load_gitrepos {
    my ($r) = @_;
    $r->{repos} = {};
    foreach my $include (@{$config->{repos_config}}) {
        load_gitrepos_dir($r->{repos}, $include);
    }
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
    $txt =~ s/$rr/$1/;
    return $txt;
}

sub load_groups {
    my ($r) = @_;
    my $ldap = get_ldap;
    my $m = $ldap->search(
        base => $config->{groupbase},
        filter => $config->{groupfilter},
    );
    my $res = $m->as_struct;
    @{$r->{groups}}{map { re('group_re', $_) } keys %$res} =
        map { [ map { re('uid_username_re', $_) } @{$_->{member}} ] }
        values %$res;
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
    };
    return process_tmpl($r->{repos}{$repo}{gl_template}, 'gl', $vars);
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

sub update_gitolite_config {
    my ($r) = @_;
    my $oldconf = -f $config->{gitolite_config} 
                ? read_file($config->{gitolite_config}) : '';
    my $newconf = gitolite_config($r);
    if ($oldconf eq $newconf) {
        print "Gitolite config didn't change\n";
        return;
    }
    write_file($config->{gitolite_config}, $newconf);
    print "TODO: Run gitolite\n";
}

1;
