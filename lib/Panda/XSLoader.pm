package Panda::XSLoader;
use strict;
use warnings;
use DynaLoader;
use Panda::Install::Payload;

=head1 NAME

Panda::XSLoader - Load XS modules which exports C functionality and check for binary compability.

=cut

sub load {
    no strict 'refs';
    shift if $_[0] && $_[0] eq __PACKAGE__;
    my ($module, $version, $flags) = @_;
    $flags = 0x01 unless defined $flags;
    $module ||= caller(0);
    *{"${module}::dl_load_flags"} = sub { $flags } if $flags;
    $version ||= ${"${module}::VERSION"};
    if (!$version and my $vsub = $module->can('VERSION')) { $version = $module->VERSION }
    
    if (my $info = Panda::Install::Payload::module_info($module)) {{
        my $bin_deps = $info->{BIN_DEPS} or last;
        foreach my $dep_module (keys %$bin_deps) {
            my $path = $dep_module;
            $path =~ s!::!/!g;
            require $path.".pm" or next;
            my $dep_version = ${"${dep_module}::VERSION"};
            if (!$dep_version and my $vsub = $dep_module->can('VERSION')) { $dep_version = $dep_module->VERSION }
            next if $dep_version eq $bin_deps->{$dep_module};
            my $dep_info = Panda::Install::Payload::module_info($dep_module) || {};
            my $bin_dependent = $dep_info->{BIN_DEPENDENT};
            $bin_dependent = [$module] if !$bin_dependent or !@$bin_dependent;
            die << "EOF";
******************************************************************************
Panda::XSLoader: XS module $module binary depends on XS module $dep_module.
$module was compiled with $dep_module version $bin_deps->{$dep_module}, but current version is $dep_version.
Please reinstall all modules that binary depend on $dep_module:
cpanm -f @$bin_dependent
******************************************************************************
EOF
        }
    }}
    
    DynaLoader::bootstrap_inherit($module, $version);
    my $stash = \%{"${module}::"};
    delete $stash->{dl_load_flags};
}
*bootstrap = *load;

=head1 SYNOPSIS

    package MyXS;
    use Panda::XSLoader;
    
    our $VERSION = '0.1.3';
    Panda::XSLoader::bootstrap(); # loads XS and checks for binary compability
    
=head1 FUNCTIONS

=head4 load ([$module], [$VERSION], [$flags])

=head4 bootstrap ([$module], [$VERSION], [$flags])

Dynamically loads your module's C library. It is more convenient usage of:

    use DynaLoader;
    sub dl_load_flags { $flags }
    DynaLoader::bootstrap_inherit($module, $VERSION);

Or (if $flags == 0)

    use XSLoader;
    XSLoader::load($module, $VERSION);

If you don't provide $module it will be detected as caller. If no $VERSION provided, ${module}::VERSION variable will be used.
If $flags is undef or not provided, 0x01 used.

Additionally, checks for binary compability with all XS modules you depend on (binary).
If any of these have changed their versions, croaks.

Note that if your module provides (exports) C functions/classes/whatever to use from another XS modules, use 0x01 in $flags.
Otherwise modules that use your functions won't load. So if it's the case then you can't use XSLoader as it doesn't provide such feature.
    
=head1 AUTHOR

Pronin Oleg <syber@crazypanda.ru>, Crazy Panda, CP Decision LTD

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
