package Panda::Install;
use strict;
use warnings;
use Exporter 'import';

our $VERSION = '0.1.2';

=head1 NAME

Panda::Install - ExtUtils::MakeMaker based module installer for XS modules.

=cut

our @EXPORT_OK = qw/payload_dir write_makefile makemaker_args/;
our @EXPORT;

if ($0 =~ /Makefile.PL$/) {
    @EXPORT = qw/write_makefile makemaker_args/;
    _require_makemaker();
}

my $xs_mask  = '*.xs';
my $xsi_mask = '*.xsi';
my $c_mask   = '*.c *.cc *.cpp *.cxx';
my $h_mask   = '*.h *.hh *.hpp *.hxx';
my $map_mask = '*.map';

sub data_dir {
    my $module = pop;
    $module =~ s/::/\//g;
    
    # first try search in loaded module's dir
    if (my $path = $INC{"$module.pm"}) {
        $path =~ s/\.pm$//;
        my $pldir = "$path.x";
        return $pldir if -d $pldir;
    }
    
    foreach my $inc (@INC) {
        my $pldir = "$inc/$module.x";
        return $pldir if -d $pldir;
    }
    
    return undef;
}

sub payload_dir {
    my $dir = data_dir(@_) or return undef;
    my $pldir = "$dir/payload";
    return $pldir if -d $pldir;
    return undef;
}

sub write_makefile {
    _require_makemaker();
    WriteMakefile(makemaker_args(@_));
}

sub makemaker_args {
    my %params = @_;
    _sync();
        
    $params{MIN_PERL_VERSION} ||= '5.10.0';
    
    my $postamble = $params{postamble};
    $postamble = {my => $postamble} if $postamble and !ref($postamble);
    $postamble ||= {};
    $postamble->{my} = '' unless defined $postamble->{my};
    $params{postamble} = $postamble;
    
    _string_merge($params{CCFLAGS}, '-o $@');

    die "You must define a NAME param" unless $params{NAME};
    unless ($params{ALL_FROM} || $params{VERSION_FROM} || $params{ABSTRACT_FROM}) {
        my $name = $params{NAME};
        $name =~ s#::#/#g;
        $params{ALL_FROM} = "lib/$name.pm";
    }
    
    if (my $package_file = delete $params{ALL_FROM}) {
        $params{VERSION_FROM}  = $package_file;
        $params{ABSTRACT_FROM} = $package_file;
    }

    $params{CONFIGURE_REQUIRES} ||= {};
    $params{CONFIGURE_REQUIRES}{'ExtUtils::MakeMaker'} ||= '6.76';
    $params{CONFIGURE_REQUIRES}{'Panda::Install'}      ||= 0;
    
    $params{BUILD_REQUIRES} ||= {};
    $params{BUILD_REQUIRES}{'ExtUtils::MakeMaker'} ||= '6.76';
    $params{BUILD_REQUIRES}{'ExtUtils::ParseXS'}   ||= '3.24';
    
    $params{TEST_REQUIRES} ||= {};
    $params{TEST_REQUIRES}{'Test::Simple'} ||= '0.96';
    $params{TEST_REQUIRES}{'Test::More'}   ||= 0;
    $params{TEST_REQUIRES}{'Test::Deep'}   ||= 0;
    
    $params{clean} ||= {};
    $params{clean}{FILES} ||= '';
    
    delete $params{PREPENDS} if $params{PREPENDS} and !%{$params{PREPENDS}};
    
    {
        my $val = $params{SRC};
        $val = [$val] if $val and ref($val) ne 'ARRAY';
        $params{SRC} = $val;
    }
    {
        my $val = $params{XS};
        $val = [$val] if $val and ref($val) ne 'ARRAY' and ref($val) ne 'HASH';
        $params{XS} = $val;
    }
    
    $params{TYPEMAPS} = [$params{TYPEMAPS}] if $params{TYPEMAPS} and ref($params{TYPEMAPS}) ne 'ARRAY';
    
    process_XS(\%params);
    process_PM(\%params);
    process_C(\%params);
    process_OBJECT(\%params);
    process_H(\%params);
    process_XSI(\%params);
    process_CLIB(\%params);
    process_PAYLOAD(\%params);
    process_DEPENDS(\%params);
    process_PREPENDS(\%params);

    if (my $use_cpp = delete $params{CPLUS}) {
        $params{CC} ||= 'c++';
        $params{LD} ||= '$(CC)';
        _string_merge($params{XSOPT}, '-C++');
    }
    
    # inject Panda::Install::ParseXS into xsubpp
    $postamble->{xsubpprun} = 'XSUBPPRUN = $(PERLRUN) -MPanda::Install::ParseXS $(XSUBPP)';

    delete $params{$_} for qw/SRC/;
    $params{OBJECT} = '$(O_FILES)' unless defined $params{OBJECT};

    return %params;
}

sub process_PM {
    my $params = shift;
    return if $params->{PM}; # user-defined value overrides defaults
    
    my $instroot = _instroot($params);
    my @name_parts = split '::', $params->{NAME};
    $params->{PMLIBDIRS} ||= ['lib', $name_parts[-1]];
    my $pm = $params->{PM} = {};
    
    foreach my $dir (@{$params->{PMLIBDIRS}}) {
        next unless -d $dir;
        foreach my $file (_scan_files('*.pm *.pl', $dir)) {
            my $rel = $file;
            $rel =~ s/^$dir//;
            my $instpath = "$instroot/$rel";
            $instpath =~ s#[/\\]{2,}#/#g;
            $pm->{$file} = $instpath;
        }
    }
}

sub process_XS {
    my $params = shift;
    my ($xs_files, @xs_list);
    if ($params->{XS}) {
        if (ref($params->{XS}) eq 'HASH') {
            $xs_files = $params->{XS};
        } else {
            push @xs_list, @{_string_split_array($_)} for @{$params->{XS}};
        }
    } else {
        @xs_list = _scan_files($xs_mask);
    }
    push @xs_list, _scan_files($xs_mask, $_) for @{$params->{SRC}};
    $params->{XS} = $xs_files ||= {};
    foreach my $xsfile (@xs_list) {
        my $cfile = $xsfile;
        $cfile =~ s/\.xs$/.c/ or next;
        $xs_files->{$xsfile} = $cfile;
    }
}

sub process_C {
    my $params = shift;
    my $c_files = $params->{C} ? _string_split_array(delete $params->{C}) : [_scan_files($c_mask)];
    push @$c_files, grep { !_includes($c_files, $_) } values %{$params->{XS}};
    push @$c_files, _scan_files($c_mask, $_) for @{$params->{SRC}};
    $params->{C} = $c_files;
}

sub process_OBJECT {
    my $params = shift;
    my $o_files = _string_split_array(delete $params->{OBJECT});
    foreach my $c_file (@{$params->{C}}) {
        my $o_file = $c_file;
        $o_file =~ s/\.[^.]+$//;
        push @$o_files, $o_file.'$(OBJ_EXT)';
    }
    $params->{OBJECT} = $o_files;
    $params->{clean}{FILES} .= ' $(O_FILES)';
}

sub process_H {
    my $params = shift;
    my $h_files = $params->{H} ? _string_split_array(delete $params->{H}) : [_scan_files($h_mask)];
    push @$h_files, _scan_files($h_mask, $_) for @{$params->{SRC}};
    $params->{H} = $h_files;
}

sub process_XSI { # make XS files rebuild if an XSI file changes
    my $params = shift;
    my @xsi_files = glob($xsi_mask);
    push @xsi_files, _scan_files($xsi_mask, $_) for @{$params->{SRC}};
    $params->{postamble}{xsi} = '$(XS_FILES):: '.join(' ', @xsi_files).'; $(TOUCH) $(XS_FILES)'."\n" if @xsi_files;
}

sub process_CLIB {
    my $params = shift;
    my $clibs = '';
    my $clib = delete $params->{CLIB} or return;
    $clib = [$clib] unless ref($clib) eq 'ARRAY';
    return unless @$clib;
    
    foreach my $info (@$clib) {
        my $make = '$(MAKE)';
        $make = 'gmake' if $info->{GMAKE} and $^O eq 'freebsd';
        my $path = $info->{DIR}.'/'.$info->{FILE};
        $clibs .= "$path ";
        $info->{TARGET} ||= ''; $info->{FLAGS} ||= '';
        $params->{postamble}{clib_build} .= "$path : ; cd $info->{DIR} && $make $info->{FLAGS} $info->{TARGET}\n";
        $params->{postamble}{clib_clean} .= "clean :: ; cd $info->{DIR} && $make clean\n";
        push @{$params->{OBJECT}}, $path;
    }
    $params->{postamble}{clib_ldep} = "linkext:: $clibs";
}

sub process_PAYLOAD {
    my $params = shift;
    my $payload = delete $params->{PAYLOAD} or return;
    _process_map($payload, '*');
    _install($params, $payload, 'payload');
}

sub process_DEPENDS {
    my $params = shift;
    my $depends = delete $params->{DEPENDS} or return;
    $depends = [$depends] unless ref($depends) eq 'ARRAY';
    _apply_DEPENDS($params, $_, {}) for @$depends;
}

sub _apply_DEPENDS {
    my ($params, $module, $seen) = @_;
    my $stop_prepending;
    $stop_prepending = 1 if $module =~ s/^-//;
    
    return if $seen->{$module}++;
    $params->{CONFIGURE_REQUIRES}{$module} ||= 0;

    my $mfile = $module;
    $mfile =~ s#::#/#g;
    $mfile .= '.x/info';
    my $info = require $mfile or next;
    
    my $extra_dir = $INC{$mfile};
    $extra_dir =~ s#/info$##;
    
    if ($info->{INCLUDE}) {
        my $incdir = "$extra_dir/i";
        $incdir =~ s#[/\\]{2,}#/#g;
        _string_merge($params->{INC}, "-I$incdir");
    }
    
    _string_merge($params->{INC},     $info->{INC});
    _string_merge($params->{CCFLAGS}, $info->{CCFLAGS});
    _string_merge($params->{DEFINE},  $info->{DEFINE});
    _string_merge($params->{XSOPT},   $info->{XSOPT});
    
    if (my $typemaps = $info->{TYPEMAPS}) {
        foreach my $typemap (reverse @$typemaps) {
            my $tmfile = "$extra_dir/tm/$typemap";
            $tmfile =~ s#[/\\]{2,}#/#g;
            unshift @{$params->{TYPEMAPS} ||= []}, $tmfile;
        }
    }
    
    if (my $add_libs = $info->{LIBS}) {{
        last unless @$add_libs;
        my $libs = $params->{LIBS} or last;
        $libs = [$libs] unless ref($libs) eq 'ARRAY';
        if ($libs and @$libs) {
            my @result;
            foreach my $l1 (@$libs) {
                foreach my $l2 (@$add_libs) {
                    push @result, "$l1 $l2";
                }
            }
            $params->{LIBS} = \@result;
        }
        else {
            $params->{LIBS} = $add_libs;
        }
    }}
    
    if (my $passthrough = $info->{PASSTHROUGH}) {
        _apply_DEPENDS($params, $_) for @$passthrough;
    }
    
    $params->{CPLUS} = 1 if $info->{CPLUS};
    
    if (my $prepends = $params->{PREPENDS} and !$stop_prepending) {
        $prepends->{PASSTHROUGH} ||= [];
        push @{$prepends->{PASSTHROUGH}}, $module;
    }
}

sub process_PREPENDS {
    my $params = shift;
    my $prepends = delete $params->{PREPENDS} or return;
    
    my $typemaps = delete($prepends->{TYPEMAPS}) || {};
    _process_map($typemaps, $map_mask);
    _install($params, $typemaps, 'tm');
    $prepends->{TYPEMAPS} = [values %$typemaps] if scalar keys %$typemaps;
    
    my $include = delete($prepends->{INCLUDE}) || {};
    _process_map($include, $h_mask);
    _install($params, $include, 'i');
    $prepends->{INCLUDE} = 1 if scalar(keys %$include);
    
    $prepends->{LIBS} = [$prepends->{LIBS}] if $prepends->{LIBS} and ref($prepends->{LIBS}) ne 'ARRAY';
    $prepends->{PASSTHROUGH} = [$prepends->{PASSTHROUGH}] if $prepends->{PASSTHROUGH} and ref($prepends->{PASSTHROUGH}) ne 'ARRAY';
    
    return unless %$prepends;
    
    require Data::Dumper;
    Data::Dumper->import('Dumper');
    
    # generate info file
    mkdir 'blib';
    local $Data::Dumper::Terse = 1;
    my $content = Dumper($prepends);
    my $infopath = 'blib/info';
    open my $fh, '>', $infopath or die "cannot open $infopath: $!";
    print $fh $content;
    close $fh;
    
    my $pm = $params->{PM} ||= {};
    $pm->{$infopath} = '$(INST_ARCHLIB)/$(FULLEXT).x/info';
}

sub _install {
    my ($params, $map, $path) = @_;
    return unless %$map;
    my $xs = $params->{XS};
    my $instroot = _instroot($params);
    my $pm = $params->{PM} ||= {};
    while (my ($source, $dest) = each %$map) {
        my $instpath = "$instroot/\$(FULLEXT).x/$path/$dest";
        $instpath =~ s#[/\\]{2,}#/#g;
        $pm->{$source} = $instpath;
    }
}

sub _instroot {
    my $params = shift;
    my $xs = $params->{XS};
    my $instroot = ($xs and %$xs) ? '$(INST_ARCHLIB)' : '$(INST_LIB)';
    return $instroot;
}

sub _sync {
    no strict 'refs';
    my $from = 'MYSOURCE';
    my $to = 'MY';
    foreach my $method (keys %{"${from}::"}) {
        next unless defined &{"${from}::$method"};
        *{"${to}::$method"} = \&{"${from}::$method"};
    }
}

sub _scan_files {
    my ($mask, $dir) = @_;
    return grep {_is_file_ok($_)} glob($mask) unless $dir;
    
    my @list = grep {_is_file_ok($_)} glob(join(' ', map {"$dir/$_"} split(' ', $mask)));
    
    opendir(my $dh, $dir) or die "Could not open dir '$dir' for scanning: $!";
    while (my $entry = readdir $dh) {
        next if $entry =~ /^\./;
        my $path = "$dir/$entry";
        next unless -d $path;
        push @list, _scan_files($mask, $path);
    }
    closedir $dh;
    
    return @list;
}

sub _is_file_ok {
    my $file = shift;
    return unless -f $file;
    return if $file =~ /\#/;
    return if $file =~ /~$/;             # emacs temp files
    return if $file =~ /,v$/;            # RCS files
    return if $file =~ m{\.swp$};        # vim swap files
    return 1;
}

sub _process_map {
    my ($map, $mask) = @_;
    foreach my $source (keys %$map) {
        my $dest = $map->{$source} || $source;
        if (-f $source) {
            $dest .= $source if $dest =~ m#[/\\]$#;
            $dest =~ s#[/\\]{2,}#/#g;
            $dest =~ s#^[/\\]+##;
            $map->{$source} = $dest;
            next;
        }
        next unless -d $source;
        
        delete $map->{$source};
        my @files = _scan_files($mask, $source);
        foreach my $file (@files) {
            my $dest_file = $file;
            $dest_file =~ s/^$source//;
            $dest_file = "$dest/$dest_file";
            $dest_file =~ s#[/\\]{2,}#/#g;
            $dest_file =~ s#^[/\\]+##;
            $map->{$file} = $dest_file;
        }
    }
}

sub _includes {
    my ($arr, $val) = @_;
    for (@$arr) { return 1 if $_ eq $val }
    return;
}

sub _string_split_array {
    my $list = shift;
    my @result;
    if ($list) {
        $list = [$list] unless ref($list) eq 'ARRAY';
        push @result, map { glob } split(' ') for @$list;
    }
    return \@result;
}

sub _string_merge {
    return unless $_[1];
    $_[0] ||= '';
    $_[0] .= $_[0] ? " $_[1]" : $_[1];
}

{
    package MYSOURCE;
    sub postamble {
        my $self = shift;
        my %args = @_;
        return join("\n", values %args);
    }
}

sub _require_makemaker {
    unless ($INC{'ExtUtils/MakeMaker.pm'}) {
        require ExtUtils::MakeMaker;
        ExtUtils::MakeMaker->import();
    }
}

=head1 DESCRIPTION

Panda::Install makes it much easier to write MakeMaker's makefiles especially for XS modules.
It provides dependecies support between XS modules, so that one could easily use header files, code, compilation
options, ...etc of another. Panda::Install also lets you put source files in subdirectories any level deep
(MakeMaker doesn't handle that) and easily compile-in external C libraries.

The params for Panda::Install are compatible with MakeMaker with some additions.

Also it supports typemap inheritance and C-like XS synopsis.

=head1 SYNOPSIS

    # Makefile.PL
    use Panda::Install;
    
    write_makefile(
        NAME    => 'My::XS',
        INC     => '-Isrc -I/usr/local/libevent/include',
        LIBS    => '-levent',
        SRC     => 'src', # all source files (code,header,xs) under 'src' are included in build
        C       => 'src2/foo.cc src2/bar.cc src3/baz/*.c', # plus src2/foo.cc, src2/bar.cc, and first-level c files in src3/baz/
        CPLUS   => 1,
        PAYLOAD => {
            # implements File::ShareDir functionality
            'data.txt'   => '/data.txt',
            'list.txt'   => '/',
            'abc.dat'    => '/mydir/bca.dat',
            'payloaddir' => '/',
        },
        DEPENDS => ['XS::Module1', 'XS::Module2'],
        PREPENDS => {
            # modules that depend on My::XS will compile with this INC, LIBS, etc set.
            TYPEMAPS    => {'typemap1.map' => '/typemap.map'},
            INC         => '-I/usr/local/libevent/include', 
            INCLUDE     => {'src' => '/'},
            LIBS        => '-levent',
            DEFINE      => '-DHELLO_FROM_MYXS',
            CCFLAGS     => 'something',
            PASSTHROUGH => 'XS::Module1',
        },
        postamble => 'mytarget: blah-blah; echo "hello"',
        CLIB => [{
            DIR    => 'libuv',
            FILE   => 'libuv.a',
            TARGET => 'libuv.a',
            FLAGS  => 'CFLAGS="-fPIC -O2"',
        }],
    );
    
=head1 TYPEMAP INHERITANCE SYNOPSIS

    T_TYPE1
        mycode1;
        
    T_TYPE2 : T_TYPE1
        mycode2;

=head1 C-LIKE XS SYNOPSIS

    char* my_xs_sub (SV* sv) { // CODE
        if (badsv(sv)) XSRETURN_UNDEF;
        RETVAL = process(sv);
    }
    
    void other_xs_sub (SV* sv) : ALIAS(other_name=1, yet_another=2) { // PPCODE
        xPUSHi(1);
        xPUSHi(2);
    }

=head1 FUNCTIONS

=head4 write_makefile(%params)

Same as WriteMakefile(makemaker_args(%params))

=head4 makemaker_args(%params)

Processes %params, does all the neccessary job and returns final parameters for passing to MakeMaker's WriteMakefile.

=head4 payload_dir($module)

Returns directory where the payload of module $module is located or undef if $module didn't install any payload.

=head2 PARAMETERS

Only differences from MakeMaker params are listed.

=over 2

=item ALL_FROM [default: NAME]

Sets ABSTRACT_FROM and VERSION_FROM to value of ALL_FROM.

If not defined, defaults to NAME. That means that if you have version and abstract in your module's main package, then
you don't need to define anything.

=item XS [*.xs]

Sets source files for xsubpp. If you define this param, defaults are aborted.

    XS => 'myxs/*.xs'
    XS => 'file1.xs folder/file2.xs folder2/*.xs'
    XS => ['file1.xs', 'folder/file2.xs folder2/*.xs']

=item C [*.c, *.cc, *.cxx, *.cpp, <xsubpp's output files>]

Sets source files to compile. If you define this param, defaults are aborted, however C files created by xsubpp are
still included.

Usage: see "XS".

=item H [*.h *.hh *.hxx *.hpp]

Sets header files for makefile's dependencies (forces module to recompile if any of these changes). Useful during development.
If you define this param, defaults are aborted.

Usage: see "XS".

=item SRC

Scans specified folder(s), finds all XS, C and H files and includes them in build. No matter whether you define XS/C/H
parameters or not, SRCs are always added to them.

    SRC => 'src'
    SRC => 'src src2 src3',
    SRC => ['src src2', 'src3'],
    
=item CPLUS

If true, will use c++ to build current extension.
    
=item postamble

Passed unchanged to Makefile. Can be HASHREF for your convenience, in which case keys are ignored, values are concatenated.

    postamble => 'sayhello: ; echo "hello"'
    postamble => {
        memd_dep   => 'linkext:: libmemd/libmemd.a; cd libmemd && $(MAKE) static',
        memd_clean => 'clean:: ; cd libmemd && $(MAKE) clean',
    }

=item MIN_PERL_VERSION [5.10.0]

Is set to 5.10.0 if you don't provide it.

=item PAYLOAD

Implements L<File::ShareDir> functionality. Specified files are installed together with module and can later be accessed
at runtime by the module itself or by other modules (via Panda::Install::payload_dir()).

Value is a HASHREF where key is a file or directory path relative to module's dist dir and value is relative to payload's
installation dir. If key is a directory then all content of that directory is installed to the destination path. If value
is not specified (undef, '') then dest path is the same as source path.

Examples (given that $payload is a directory where payload is installed and $dist is a module's dist dir):

    'file.txt' => ''       # $dist/file.txt => $payload/file.txt
    'file.txt' => 'a.txt'  # $dist/file.txt => $payload/a.txt
    'mydir'    => '',      # $dist/mydir    => $payload/mydir
    'mydir'    => 'a/b/c', # $dist/mydir/*  => $payload/a/b/c/*
    'mydir'    => '/',     # $dist/mydir/*  => $payload/*

=item DEPENDS

List of modules current module depends on. That means all that those modules specified in PREPENDS section will be applied
while building current module. It also adds those modules to CONFIGURE_REQUIRES section.

Also if your module has PREPENDS section then all modules in DEPENDS goes to PREPENDS/PASSTHROUGH unless module name is prefixed
with '-' (minus).

Examples:

    DEPENDS => 'Module1'
    DEPENDS => ['Module1', '-Module2']

=item PREPENDS

In this section you put values that you want to be applied to any module which specified your module as a dependency.

=item PREPENDS/TYPEMAPS

Installs specified typemaps and also adds it to the list of typemaps when building descendant modules.

Receives HASHREF, format is the same as for PAYLOAD, the only difference is that it scans folders for *.map files only.

=item PREPENDS/INC

Adds include file dirs to INC when building descendant modules.

=item PREPENDS/INCLUDE

Installs specified include files/dirs into module's installation include directory and adds that directory to INC
when building descendant modules.

=item PREPENDS/LIBS

Added to LIBS when building descendant modules.

=item PREPENDS/DEFINE

Added to DEFINE when building descendant modules.

=item PREPENDS/CCFLAGS

Added to CCFLAGS when building descendant modules.

=item PREPENDS/XSOPT

Added to XSOPT when building descendant modules.

=item PREPENDS/PASSTHROUGH

Merge 'PREPENDS' of this module with 'PREPENDS' of specified modules. Everything gets concatenated (strings, arrays, etc) while merging.
You don't need to manually manage this setting as it's managed automatically (see DEPENDS section).

=item CLIB

List of external C libraries that need to be built and compiled into the extension.

=item CLIB/DIR

Directory where external library is. Makefile must present in that directory!

=item CLIB/FILE

Static library file which is built by the library (relative to CLIB/DIR).

=item CLIB/TARGET

Name of the target for Makefile to built static library.

=item CLIB/FLAGS

Flags to build external library with.

=back

=head1 TYPEMAP INHERITANCE

=head4 Output typemaps

    T_TYPE1
        mycode1;
        
    T_TYPE2 : T_TYPE1
        mycode2;
        
T_TYPE2 will have mycode1 inserted after mycode2 as if it was written

    T_TYPE2
        mycode2;
        mycode1;
        
=head4 Input typemaps

    T_TYPE1
        mycode1;
        
    T_TYPE2 : T_TYPE1
        mycode2;
        
T_TYPE2 will have mycode1 inserted before mycode2 as if it was written

    T_TYPE2
        mycode1;
        mycode2;

=head1 C-LIKE XS

If you're using Panda::Install then all of your XS files support C-like XS. It means that code
    
    char* my_xs_sub (SV* sv) { // CODE
        if (badsv(sv)) XSRETURN_UNDEF;
        RETVAL = process(sv);
    }
    
    void other_xs_sub (SV* sv) : ALIAS(other_name=1, yet_another=2) { // PPCODE
        xPUSHi(1);
        xPUSHi(2);
    }
        
is replaced with code

    char*
    my_xs_sub (SV* sv)
    CODE:
        if (badsv(sv)) XSRETURN_UNDEF;
        RETVAL = process(sv);
    OUTPUT:
        RETVAL
    
    void
    other_xs_sub (SV* sv)
    ALIAS:
        other_name=1
        yet_another=2
    PPCODE:
        xPUSHi(1);
        xPUSHi(2);
    
=head1 AUTHOR

Pronin Oleg <syber@crazypanda.ru>, Crazy Panda, CP Decision LTD

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
