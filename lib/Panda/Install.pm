package Panda::Install;
use strict;
use warnings;
use Exporter 'import';
use Panda::Install::Payload;

our $VERSION = '0.2.1';

=head1 NAME

Panda::Install - ExtUtils::MakeMaker based module installer for XS modules.

=cut

our @EXPORT_OK = qw/write_makefile makemaker_args/;
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
    $params{CONFIGURE_REQUIRES}{'Panda::Install'}      ||= $VERSION;
    
    $params{BUILD_REQUIRES} ||= {};
    $params{BUILD_REQUIRES}{'ExtUtils::MakeMaker'} ||= '6.76';
    $params{BUILD_REQUIRES}{'ExtUtils::ParseXS'}   ||= '3.24';
    
    $params{TEST_REQUIRES} ||= {};
    $params{TEST_REQUIRES}{'Test::Simple'} ||= '0.96';
    $params{TEST_REQUIRES}{'Test::More'}   ||= 0;
    $params{TEST_REQUIRES}{'Test::Deep'}   ||= 0;
    
    $params{PREREQ_PM} ||= {};
    $params{PREREQ_PM}{'Panda::Install'} ||= $VERSION; # needed at runtime because it has payload_dir and xsloader
    
    $params{clean} ||= {};
    $params{clean}{FILES} ||= '';
    
    delete $params{BIN_SHARE} if $params{BIN_SHARE} and !%{$params{BIN_SHARE}};
    
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
    
    my $module_info = Panda::Install::Payload::module_info($params{NAME}) || {};
    $params{MODULE_INFO} = {BIN_DEPENDENT => $module_info->{BIN_DEPENDENT}};
    
    process_XS(\%params);
    process_PM(\%params);
    process_C(\%params);
    process_OBJECT(\%params);
    process_H(\%params);
    process_XSI(\%params);
    process_CLIB(\%params);
    process_PAYLOAD(\%params);
    process_BIN_DEPS(\%params);
    process_BIN_SHARE(\%params);
    attach_BIN_DEPENDENT(\%params);
    warn_BIN_DEPENDENT(\%params);

    if (my $use_cpp = delete $params{CPLUS}) {
        $params{CC} ||= 'c++';
        $params{LD} ||= '$(CC)';
        _string_merge($params{XSOPT}, '-C++');
    }
    
    # inject Panda::Install::ParseXS into xsubpp
    $postamble->{xsubpprun} = 'XSUBPPRUN = $(PERLRUN) -MPanda::Install::ParseXS $(XSUBPP)';

    delete $params{$_} for qw/SRC/;
    $params{OBJECT} = '$(O_FILES)' unless defined $params{OBJECT};
    
    delete $params{MODULE_INFO};

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

sub process_BIN_DEPS {
    my $params = shift;
    my $bin_deps = delete $params->{BIN_DEPS} or return;
    $bin_deps = [$bin_deps] unless ref($bin_deps) eq 'ARRAY';
    _apply_BIN_DEPS($params, $_, {}) for @$bin_deps;
}

sub _apply_BIN_DEPS {
    my ($params, $module, $seen) = @_;
    my $stop_sharing;
    $stop_sharing = 1 if $module =~ s/^-//;
    
    return if $seen->{$module}++;
    
    my $installed_version = Panda::Install::Payload::module_version($module);
    $params->{CONFIGURE_REQUIRES}{$module}  ||= $installed_version;
    $params->{PREREQ_PM}{$module}           ||= $installed_version;
    $params->{MODULE_INFO}{BIN_DEPS}{$module} = $installed_version;

    my $info = Panda::Install::Payload::module_info($module);
    
    if ($info->{INCLUDE}) {
        my $incdir = Panda::Install::Payload::include_dir($module);
        _string_merge($params->{INC}, "-I$incdir");
    }
    
    _string_merge($params->{INC},     $info->{INC});
    _string_merge($params->{CCFLAGS}, $info->{CCFLAGS});
    _string_merge($params->{DEFINE},  $info->{DEFINE});
    _string_merge($params->{XSOPT},   $info->{XSOPT});
    
    if (my $typemaps = $info->{TYPEMAPS}) {
        my $tm_dir = Panda::Install::Payload::typemap_dir($module);
        foreach my $typemap (reverse @$typemaps) {
            my $tmfile = "$tm_dir/$typemap";
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
        _apply_BIN_DEPS($params, $_) for @$passthrough;
    }
    
    $params->{CPLUS} = 1 if $info->{CPLUS};
    
    if (my $bin_share = $params->{BIN_SHARE} and !$stop_sharing) {
        push @{$bin_share->{PASSTHROUGH} ||= []}, $module;
    }
}

sub process_BIN_SHARE {
    my $params = shift;
    my $bin_share = delete $params->{BIN_SHARE} or return;
    
    my $typemaps = delete($bin_share->{TYPEMAPS}) || {};
    _process_map($typemaps, $map_mask);
    _install($params, $typemaps, 'tm');
    $bin_share->{TYPEMAPS} = [values %$typemaps] if scalar keys %$typemaps;
    
    my $include = delete($bin_share->{INCLUDE}) || {};
    _process_map($include, $h_mask);
    _install($params, $include, 'i');
    $bin_share->{INCLUDE} = 1 if scalar(keys %$include);
    
    $bin_share->{LIBS} = [$bin_share->{LIBS}] if $bin_share->{LIBS} and ref($bin_share->{LIBS}) ne 'ARRAY';
    $bin_share->{PASSTHROUGH} = [$bin_share->{PASSTHROUGH}] if $bin_share->{PASSTHROUGH} and ref($bin_share->{PASSTHROUGH}) ne 'ARRAY';
    
    if (my $list = $params->{MODULE_INFO}{BIN_DEPENDENT}) {
        $bin_share->{BIN_DEPENDENT} = $list if @$list;
    }
    
    if (my $vinfo = $params->{MODULE_INFO}{BIN_DEPS}) {
        $bin_share->{BIN_DEPS} = $vinfo if %$vinfo;
    }
    
    return unless %$bin_share;
    
    # generate info file
    mkdir 'blib';
    my $infopath = 'blib/info';
    _module_info_write($infopath, $bin_share);
    
    my $pm = $params->{PM} ||= {};
    $pm->{$infopath} = '$(INST_ARCHLIB)/$(FULLEXT).x/info';
}

sub attach_BIN_DEPENDENT {
    my $params = shift;
    my @deps = keys %{$params->{MODULE_INFO}{BIN_DEPS} || {}};
    return unless @deps;
    
    $params->{postamble}{sync_bin_deps} =
        "sync_bin_deps:\n".
        "\t\$(PERL) -MPanda::Install -e 'Panda::Install::cmd_sync_bin_deps()' $params->{NAME} @deps\n".
        "install :: sync_bin_deps";
}

sub warn_BIN_DEPENDENT {
    my $params = shift;
    return unless $params->{VERSION_FROM};
    my $module = $params->{NAME};
    my $list = $params->{MODULE_INFO}{BIN_DEPENDENT} or return;
    return unless @$list;
    my $installed_version = Panda::Install::Payload::module_version($module) or return;
    my $mm = bless {}, 'MM';
    my $new_version = $mm->parse_version($params->{VERSION_FROM}) or return;
    return if $installed_version eq $new_version;
    warn << "EOF";
******************************************************************************
Panda::Install: There are XS modules that binary depend on current XS module $module.
They were built with currently installed $module version $installed_version.
If you install $module version $new_version, you will have to reinstall all XS modules that binary depend on it:
cpanm -f @$list
******************************************************************************
EOF
}

sub cmd_sync_bin_deps {
    my $myself = shift @ARGV;
    my @modules = @ARGV;
    foreach my $module (@modules) {
        my $info = Panda::Install::Payload::module_info($module) or next;
        my $dependent = $info->{BIN_DEPENDENT} || [];
        my %tmp = map {$_ => 1} grep {$_ ne $module} @$dependent;
        $tmp{$myself} = 1;
        $info->{BIN_DEPENDENT} = [sort keys %tmp];
        delete $info->{BIN_DEPENDENT} unless @{$info->{BIN_DEPENDENT}};
        my $file = Panda::Install::Payload::module_info_file($module);
        _module_info_write($file, $info);
    }
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
    package
        MYSOURCE;
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

sub _module_info_write {
    my ($file, $info) = @_;
    require Data::Dumper;
    local $Data::Dumper::Terse = 1;
    local $Data::Dumper::Indent = 0;
    my $content = Data::Dumper::Dumper($info);
    my $restore_mode;
    if (-e $file) { # make sure we have permissions to write, because perl installs files with 444 perms
        my $mode = (stat $file)[2];
        unless ($mode & 0200) { # if not, temporary enable write permissions
            $restore_mode = $mode;
            $mode |= 0200;
            chmod $mode, $file;
        }
    }
    open my $fh, '>', $file or die "Cannot open $file for writing: $!";
    print $fh $content;
    close $fh;
    
    chmod $restore_mode, $file if $restore_mode; # restore old perms if we changed it
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
        BIN_DEPS  => ['XS::Module1', 'XS::Module2'],
        BIN_SHARE => {
            # modules that depend on My::XS will compile with this INC, LIBS, etc set.
            TYPEMAPS    => {'typemap1.map' => '/typemap.map'},
            INC         => '-I/usr/local/libevent/include', 
            INCLUDE     => {'src' => '/'},
            LIBS        => '-levent',
            DEFINE      => '-DHELLO_FROM_MYXS',
            CCFLAGS     => 'something',
        },
        postamble => 'mytarget: blah-blah; echo "hello"',
        CLIB => [{
            DIR    => 'libuv',
            FILE   => 'libuv.a',
            TARGET => 'libuv.a',
            FLAGS  => 'CFLAGS="-fPIC -O2"',
        }],
    );
    
=head1 LOADING XS MODULE SYNOPSIS

    package MyXSModule;
    use Panda::XSLoader;
    
    our $VERSION = '1.0.0';
    Panda::XSLoader::load(); # same as Panda::XSLoader::load('MyXSModule', $VERSION, 0x01);
    
see L<Panda::XSLoader>
    
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
    
=head1 GETTING PAYLOAD SYNOPSIS

    my $payload_dir = Panda::Install::Payload::payload_dir('My::Module');
    
see L<Panda::Install::Payload>

=head1 TYPEMAP CAST SYNOPSIS

    bool
    filter (AV* users, const char* what)
    CODE:
        for (int i = 0; i <= av_len(users); ++i) {
            User* user = typemap_incast<User*>(av_fetch(users, i, 0));
            if (...) XSRETURN_TRUE;
        }
        XSRETURN_FALSE;
    OUTPUT:
        RETVAL
    
    
    AV*
    MyStorage::get_sites ()
    CODE:
        RETVAL = newAV();
        for (int i = 0; i < THIS->urls.length(); ++i) {
            SV* uri_perl_obj = typemap_outcast<URI*, const char* CLASS>(THIS->urls[i], "My::URI");
            av_push(RETVAL, uri_perl_obj);
        }
    OUTPUT:
        RETVAL

=head1 FUNCTIONS

=head4 write_makefile(%params)

Same as WriteMakefile(makemaker_args(%params))

=head4 makemaker_args(%params)

Processes %params, does all the neccessary job and returns final parameters for passing to MakeMaker's WriteMakefile.

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
at runtime by the module itself or by other modules (via L<Panda::Install::Payload>'s payload_dir()).

Value is a HASHREF where key is a file or directory path relative to module's dist dir and value is relative to payload's
installation dir. If key is a directory then all content of that directory is installed to the destination path. If value
is not specified (undef, '') then dest path is the same as source path.

Examples (given that $payload is a directory where payload is installed and $dist is a module's dist dir):

    'file.txt' => ''       # $dist/file.txt => $payload/file.txt
    'file.txt' => 'a.txt'  # $dist/file.txt => $payload/a.txt
    'mydir'    => '',      # $dist/mydir    => $payload/mydir
    'mydir'    => 'a/b/c', # $dist/mydir/*  => $payload/a/b/c/*
    'mydir'    => '/',     # $dist/mydir/*  => $payload/*

=item BIN_DEPS

List of modules current module binary depends on. That means all that those modules specified in BIN_SHARE section will be applied
while building current module. It also adds those modules to CONFIGURE_REQUIRES and PREREQ_PM sections.

Also if your module has BIN_SHARE section then all modules in BIN_DEPS goes to BIN_SHARE/PASSTHROUGH unless module name is prefixed
with '-' (minus).

Examples:

    BIN_DEPS => 'Module1'
    BIN_DEPS => ['Module1', '-Module2']

=item BIN_SHARE

In this section you put values that you want to be applied to any module which specified your module as a dependency.

=item BIN_SHARE/TYPEMAPS

Installs specified typemaps and also adds it to the list of typemaps when building descendant modules.

Receives HASHREF, format is the same as for PAYLOAD, the only difference is that it scans folders for *.map files only.

=item BIN_SHARE/INC

Adds include file dirs to INC when building descendant modules.

=item BIN_SHARE/INCLUDE

Installs specified include files/dirs into module's installation include directory and adds that directory to INC
when building descendant modules.

Receives HASHREF, format is the same as for PAYLOAD, the only difference is that it scans folders for header files only.

=item BIN_SHARE/LIBS

Added to LIBS when building descendant modules.

=item BIN_SHARE/DEFINE

Added to DEFINE when building descendant modules.

=item BIN_SHARE/CCFLAGS

Added to CCFLAGS when building descendant modules.

=item BIN_SHARE/XSOPT

Added to XSOPT when building descendant modules.

=item BIN_SHARE/PASSTHROUGH

Merge 'BIN_SHARE' of this module with 'BIN_SHARE' of specified modules. Everything gets concatenated (strings, arrays, etc) while merging.
You don't need to manually manage this setting as it's managed automatically (see BIN_DEPS section).

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

=head1 TYPEMAP FEATURES

=head2 TYPEMAP INHERITANCE

=head3 Output typemaps

    T_TYPE1
        mycode1;
        
    T_TYPE2 : T_TYPE1
        mycode2;
        
T_TYPE2 will have mycode1 inserted after mycode2 as if it was written

    T_TYPE2
        mycode2;
        mycode1;
        
=head3 Input typemaps

    T_TYPE1
        mycode1;
        
    T_TYPE2 : T_TYPE1
        mycode2;
        
T_TYPE2 will have mycode1 inserted before mycode2 as if it was written

    T_TYPE2
        mycode1;
        mycode2;

=head3 Passing params

You can pass params when inheriting typemaps. These params can be accessed in parent typemap via %p hash.

    T_TYPE1
        int $p{varname} = 150;
        mycode1;
        $p{expr};

    T_TYPE2 : T_TYPE1(varname=myvar, expr="myvar = a + b")
        mycode2;

will result in (for input typemap)

    T_TYPE2
        int myvar = 150;
        mycode1;
        myvar = a + b;
        mycode2;

=head2 TYPEMAP INIT CODE

In OUTPUT typemaps you can use 'INIT: expr;' expressions. These expressions later will be moved to the top of the XS function like 
INIT: section of XS function itself. It is useful for typemaps which want to predefine some variable, so that user has a chance
to change it. Such typemaps then use this variable in its code. For example:

    TYPEMAP
    
    int MY_TYPE

    OUTPUT
    
    MY_TYPE
        INIT: int lolo = 0;
        sv_setiv($arg, $var + lolo);
        
    
    #XS
    
    int
    myfunc () 
    CODE:
        lolo = 10;
        RETVAL = 20; // returns 30
    OUTPUT:
        RETVAL;

=head2 TYPEMAP CAST

Sometimes the type of data you receive or return depends on something and therefore you cannot use certain input or output typemap.
To help you dealing with this, there are typemap input and output cast operators (for XS code).

=head4 template <class T> T typemap_incast (SV* input)

Does what INPUT typemap "T" would do. Returns T.

Can ONLY be used inside XS functions.

=head4 template <class T> SV* typemap_outcast (T output)

Does what OUTPUT typemap "T" would do. Returns SV*.

Can ONLY be used inside XS functions.

=head4 template <class T, arg def1, arg def2, ...> SV* typemap_outcast (T output, arg1, arg2, ...)

This is an extended version of typemap_outcast, which is useful if typemap "T" requires additional variables to be predefined.
For example, typemaps which create objects, often require "const char* CLASS = ..." variable to be defined.
In this case you need to define these variables right after typemap type and pass all of them as a parameters to typemap cast
function:

    ... = typemap_outcast<MyClass*, const char* CLASS, bool do_checks, SV* extra>(new MyClass(), "My::Class", true, myextra);

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
    
Note that writing

    int myfunc (int a)
    
will result in default ParseXS behaviour (calling C function myfunc(a) and returning its result). That's because it has no body.

However this function has a body (empty) and therefore prevents default behaviour

    int myfunc (int a) {}

=head1 AUTHOR

Pronin Oleg <syber@crazypanda.ru>, Crazy Panda, CP Decision LTD

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
