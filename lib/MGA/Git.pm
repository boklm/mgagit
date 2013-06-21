package MGA::Git;

use strict;
use YAML qw(LoadFile);
use IO::File;
use Template;
use File::Slurp;
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
}

sub load_gitrepos {
    my ($r) = @_;
    $r->{repos} = {};
    foreach my $include (@{$config->{repos_config}}) {
        load_gitrepos_dir($r->{repos}, $include);
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

sub gitolite_repo_config {
    my ($r, $repo) = @_;
    my $tt = Template->new;
    my $tmpl = get_tmpl($r->{repos}{$repo}{gl_template}, 'gl');
    my $vars = {
        r      => $r,
        repo   => $repo,
        config => $config,
    };
    my $c;
    $tt->process(\$tmpl, $vars, \$c);
    return $c;
}

sub gitolite_config {
    my ($r) = @_;
    my @repos;
    @repos = map { gitolite_repo_config($r, $_) } sort keys %{$r->{repos}};
    return join("\n", @repos);
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
