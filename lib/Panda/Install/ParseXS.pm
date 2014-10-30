package
    Panda::Install::ParseXS;
use strict;
use warnings;
use feature 'state';
use ExtUtils::ParseXS;
use ExtUtils::ParseXS::Eval;
use ExtUtils::ParseXS::Utilities;
use ExtUtils::Typemaps;
use ExtUtils::Typemaps::InputMap;
use ExtUtils::Typemaps::OutputMap;

=head1 NAME

Panda::Install::ParseXS - Adds new features for TYPEMAPS and XS code

=cut

our ($top_typemaps, $cur_typemaps);
our %code_params;

sub map_postprocess {
    my $map = shift;
    my $is_output = $map->isa('ExtUtils::Typemaps::OutputMap') || 0;
    my $type = $is_output ? 'OUTPUT' : 'INPUT';
    my $code = $map->code;
    $code = "" unless $code =~ /\S/;
    $code =~ s/\s+$//;
    $code =~ s/\t/    /g;
    #$code =~ s#^(.*)$#sprintf("%-80s%s", "$1", "/* $map->{xstype} */")#mge if $code;
    my @attrs = qw/PREVENT_DEFAULT_DELETE_ON_EMPTY_DESTROY/;
    my $initcode = '';
    
    if ($map->{xstype} =~ s/^(.+?)\s+:\s+([^() ]+)\s*(\(((?:[^()]+|(?3))*)\))?$/$1/) {
        my $parent_xstype = $2;
        my $parent_params = $4;
        my $parent_map = $is_output ? outmap($parent_xstype) : inmap($parent_xstype);
        die "\e[31m No parent $parent_xstype found in $type map \e[0m" unless $parent_map;
        my $parent_code = $parent_map->code;
        $initcode = $parent_map->{_init_code};
        $map->{_attrs}{$_} = $parent_map->{_attrs}{$_} for @attrs;
        
        if ($parent_params and $parent_code) {
            my @pairs = split /\s*,\s*/, $parent_params;
            foreach my $pair (@pairs) {
                my ($k,$v) = split /\s*=\s*/, $pair, 2;
                $v //= '';
                if (index($v, '"') == 0 and rindex($v, '"') == length($v) - 1) {
                    substr($v, 0, 1, '');
                    chop($v);
                }
                $parent_code = "    \${ \$p{'$k'} //= '$v'; \\''; }\n$parent_code";
            }
        }
        
        if ($code =~ /TYPEMAP::SUPER\(\)\s*;/) {
            $code =~ s/\s*TYPEMAP::SUPER\(\)\s*;/$parent_code/;
        }
        elsif ($is_output) {
            $code .= "\n" if $code;
            $code .= $parent_code;
        } else {
            my $prevcode = $code;
            $code = $parent_code;
            $code .= "\n$prevcode" if $prevcode;
        }
    }
    
    # MOVE AWAY 'INIT: ...' code. It will be used in fetch_para to insert it into the top of the function
    while ($code =~ s/^\s*INIT:(.+)//m) {
        my $line = $1;
        $line =~ s/^\s+//;
        $line =~ s/\s+$//;
        $initcode .= "$line\n";
    }
        
    $map->{_init_code} = $initcode;
    
    foreach my $attr (@attrs) {
        next unless $code =~ s/^\s*\@$attr\s*(?:=\s*(.+))?$//mg;
        $map->{_attrs}{$attr} = $1 // 1;
        $map->{_attrs}{$attr} =~ s/\s+$//;
    }
    
    if ($is_output) {
        # if code has '$arg = <something>' not in first line - prevent fuckin ExtUtils::ParseXS from adding '$arg = sv_newmortal()'
        # triggered by $arg = NULL which must firstly be set by typemap itself. Move it on top if inheriting
        #state $ppline = '    $arg = NULL; /* suppress xsubpp\'s pollution of $arg */';
        my $found = ($code =~ s/^\s*\$arg\s*=\s*\NULL\s*;\s*$//gm); # remove previous guardians;
        $code = "    \$arg = NULL;\n$code" if $found;
        $code =~ s/\n\s*\n/\n/gm;
    }
    
    $map->code($code);
}

sub outmap { return $cur_typemaps->get_outputmap(xstype => $_[0]) || $top_typemaps->get_outputmap(xstype => $_[0]); }
sub inmap  { return $cur_typemaps->get_inputmap(xstype => $_[0]) || $top_typemaps->get_inputmap(xstype => $_[0]); }

package
    ExtUtils::ParseXS; # hide from pause
use strict;
use warnings;

    # pre process     # post process
my ($orig_fetch_para, $orig_print_section);

BEGIN {
    $orig_fetch_para = \&fetch_para;
    $orig_print_section = \&print_section;
    no strict 'refs';
    delete ${__PACKAGE__.'::'}{fetch_para};
    delete ${__PACKAGE__.'::'}{print_section};
    delete ${__PACKAGE__.'::'}{eval_output_typemap_code};
    delete ${__PACKAGE__.'::'}{eval_input_typemap_code};
}

# pre process XS function
sub fetch_para {
    my $self = shift;
    my $ret = $orig_fetch_para->($self, @_);
    my $lines = $self->{line};
    my $linno = $self->{line_no};
    
    if ($lines->[0] and $lines->[0] =~ /^([A-Z]+)\s*\{/) {
        $lines->[0] = "$1:";
        if ($lines->[-1] =~ /^\}/) { pop @$lines; pop @$linno; }
    }
    
    my $re_alias = qr/ALIAS\s*\(([^()]+)\)/;
    if ($lines->[0] and $lines->[0] =~ /^(.+?)\s+([^\s()]+\s*(\((?:[^()]+|(?3))*\)))\s*(?::\s*(?:$re_alias)?)?\s*\{?/) {
        my ($type, $sig, $alias) = ($1, $2, $4);
        my $remove_closing;
        
        if ((my $idx = index($lines->[0], '{')) > 0) { # move following text on next line
            $remove_closing = 1;
            my $content = substr($lines->[0], $idx);
            if ($content !~ /^\{\s*$/) {
                $content =~ s/^\{//;
                splice(@$lines, 1, 0, $content);
                splice(@$linno, 1, 0, $linno->[0]);
            }
        } elsif ($lines->[1] and $lines->[1] =~ s/^\s*\{//) { # '{' on next line
            $remove_closing = 1;
            if ($lines->[1] !~ /\S/) { # nothing remains, delete entire line
                splice(@$lines, 1, 1);
                splice(@$linno, 1, 1);
            }
        }

        if ($remove_closing) {
            $lines->[-1] =~ s/}\s*;?\s*$//;
            if ($lines->[-1] !~ /\S/) { pop @$lines; pop @$linno; }
            
            if (!$lines->[1] or $lines->[1] !~ /\S/) { # no code remains, but body was present ({}), add empty code to prevent default behaviour
                splice(@$lines, 1, 0, ' ');
                splice(@$linno, 1, 0, $linno->[0]);
            }
        }
        
        $lines->[0] = $type;
        
        if (!$lines->[1]) {{ # empty sub
            my ($class, $func, $var);
            if ($sig =~ /^([^:]+)::([a-zA-Z0-9_\$]+)/) {
                ($class, $func, $var) = ("$1*", $2, 'THIS');
            } elsif ($sig =~ /^([a-zA-Z0-9_\$]+)\s*\(\s*([a-zA-Z0-9_\$*]+)\s+\*?([a-zA-Z0-9_\$]+)\)/) {
                ($class, $func, $var) = ($2, $1, $3);
            } else { last }
            my $in_tmap = $self->{typemap}->get_inputmap(ctype => $class) or last;
            if ($func eq 'DESTROY' and $var eq 'THIS' and $in_tmap->{_attrs}{PREVENT_DEFAULT_DELETE_ON_EMPTY_DESTROY}) {
                splice(@$lines, 1, 0, ' ');
                splice(@$linno, 1, 0, $linno->[0]);
            }
        }}
                
        if ($lines->[1] and $lines->[1] !~ /^[A-Z]+\s*:/) {
            splice(@$lines, 1, 0, $type =~ /^void(\s|$)/ ? 'PPCODE:' : 'CODE:');
            splice(@$linno, 1, 0, $linno->[0]);
        }
        
        if ($alias) {
            my @alias = split /\s*,\s*/, $alias;
            if (@alias) {
                foreach my $alias_entry (reverse @alias) {
                    splice(@$lines, 1, 0, "    $alias_entry");
                    splice(@$linno, 1, 0, $linno->[0]);
                }
                splice(@$lines, 1, 0, 'ALIAS:');
                splice(@$linno, 1, 0, $linno->[0]);
            }
        }
        
        splice(@$lines, 1, 0, $sig);
        splice(@$linno, 1, 0, $linno->[0]);
    }

    my $para = join("\n", @$lines);
    
    if ($para =~ /^CODE\s*:/m and $para !~ /^OUTPUT\s*:/m) {
        push @$lines, 'OUTPUT:', '    RETVAL';
        push @$linno, $linno->[-1]+1 for 1..2;
        $para = join("\n", @$lines);
    }
    
    if (my $out_ctype = $lines->[0]) {{
        $out_ctype =~ s/^\s+//g;
        $out_ctype =~ s/\s+$//g;
        my $out_tmap = $self->{typemap}->get_outputmap(ctype => $out_ctype) or last;
        my $init_code = $out_tmap->{_init_code} or last;
        my $idx;
        for (my $i = 2; $i < @$lines; ++$i) {
            next unless $lines->[$i] =~ /^\s*[a-zA-Z0-9]+\s*:/;
            $idx = $i;
            last;
        }
        last unless $idx;
        splice(@$lines, $idx, 0, $init_code);
        splice(@$linno, $idx, 0, $linno->[0]);
    }}
    
    return $ret;
}

# post process XS function
sub print_section {
    my $self = shift;
    my $lines = $self->{line};
    my $linno = $self->{line_no};
    
    # find typemap_in|outcast<>()
    state $re_parens = qr/(\((?:(?>[^()]+)|(?-1))*\))/;
    state $re_gtlt = qr/(<(?:(?>[^<>]+)|(?-1))*>)/;
    my %gen_funcs;
    foreach my $row (['typemap_incast', 1], ['typemap_outcast', 0]) {
        my ($kword, $is_input) = @$row;
        my $re = qr/\b$kword\s*(?<CLASS>$re_gtlt)\s*(?<EXPR>$re_parens)/;
        foreach my $line (@$lines) {
            while ($line =~ $re) {
                my ($class, $expr) = @+{'CLASS', 'EXPR'};
                $class =~ s/^<//;
                $class =~ s/>$//;
                my @args;
                ($class, @args) = split /\s*,\s*/, $class;
                for (@args) {
                    s/^\s+//; s/\s+$//;
                    die "\e[31m Typemap parameter must have a type at '$_' \e[0m" unless /^(.+?)([a-zA-Z0-9_\$]+)$/;
                    my ($type, $name) = ($1, $2);
                    $type =~ s/\s+\*/*/g;
                    $type =~ s/\s+$//;
                    $_ = [$type, $name];
                }
                
                my $meth = $is_input ? 'get_inputmap' : 'get_outputmap';
                my $tmap = $self->{typemap}->$meth(ctype => $class);
                die "\e[31m No typemap found for '$kword<$class>()', line '$line' \e[0m" unless $tmap;
                my $subtype = $class; $subtype =~ s/\s*\*$//;
                my $ntype   = $class; $ntype   =~ s/\s*\*$/Ptr/;
                my $tmfunc_name = "_${kword}_${ntype}_".join("_", map {"@$_"} @args);
                $tmfunc_name =~ s/\*/Ptr/g;
                $tmfunc_name =~ s/\s/_/g;
                unless ($gen_funcs{$tmfunc_name}) {
                    my $other = {
                        var     => 'var',
                        type    => $class,
                        subtype => $subtype,
                        ntype   => $ntype,
                        arg     => 'arg',
                    };
                    if ($is_input) {
                        $other->{num}          = -1; # not on stack
                        $other->{init}         = undef;
                        $other->{printed_name} = 0;
                        $other->{argoff}       = -1; # not on stack
                    }
                    $meth = $is_input ? 'eval_input_typemap_code' : 'eval_output_typemap_code';
                    my $tmcode = $tmap->code;
                    my $code = $self->$meth("qq\a$tmcode\a", $other);
                    my $arg_init = (!$is_input && $tmcode =~ /^\s*\$arg\s*=\s*\NULL\s*;\s*$/m) ? '' : ' = newSV(0)';
                    my $tmfunc_code = _typemap_inline_func($tmfunc_name, $class, $code, $arg_init, $is_input, \@args, $tmap->{_init_code});
                    $gen_funcs{$tmfunc_name} = $tmfunc_code;
                }
                $line =~ s/$re/${tmfunc_name}::get$expr/;
            }
        }
    }
    
    my $gen_code = join "", values %gen_funcs;
    print $gen_code;
    
    return $gen_code.$orig_print_section->($self, @_);
}

sub _typemap_inline_func {
    my ($tmfunc_name, $class, $code, $arg_init, $is_input, $args, $tm_init) = @_;
    $code =~ s/^\s+//s;
    $code =~ s/\s+$//s;
    my $additional_args = @$args ? ", ".join(", ", map { "$_->[0] $_->[1]" } @$args) : '';
    
    if ($tm_init and @$args) {
        # if some custom typemap variable is defined and set in typemap INIT section, and is present in $args,
        # we must remove it to give user a chance to redefine it. Ugly, but there are no other chance with ugly ExtUtils::ParseXS.
        for (@$args) {
            my ($type, $name) = @$_;
            $type =~ s/\*/\\s*\\*/g;
            $tm_init =~ s/((?:^\s*|;\s*|\}\s*)$type\s+)($name)\b/${1}__pxs_${2}_off__/s;
        }
    }
    $code = "$tm_init\n    $code" if $tm_init;
    $code =~ s/^[\s;]+$//mg;
    $code =~ s/\n\n+/\n/g;
    
    $code =~ s/^/        /mg;
    return << "EOF" if $is_input;
        struct $tmfunc_name { static inline $class get (SV* arg$additional_args) {
            $class var;\n    $code;
            return var;
        }};
EOF
    return << "EOF";
        struct $tmfunc_name { static inline SV* get ($class var$additional_args) {
            SV* arg$arg_init;\n    $code;
            return arg;
        }};
EOF
}

sub eval_output_typemap_code {
    my ($self, $code, $other) = @_;
    my ($Package, $ALIAS, $func_name, $Full_func_name, $pname) = @{$self}{qw(Package ALIAS func_name Full_func_name pname)};
    my ($var, $type, $ntype, $subtype, $arg) = @{$other}{qw(var type ntype subtype arg)};
    my %p;
  
    no warnings 'uninitialized';
    my $rv = eval $code;
    die "Error evaling typemap: $@\nTypemap code was:\n$code" if $@;
    return $rv;
}

sub eval_input_typemap_code {
    my ($self, $code, $other) = @_;
    my ($Package, $ALIAS, $func_name, $Full_func_name, $pname) = @{$self}{qw(Package ALIAS func_name Full_func_name pname)};
    my ($var, $type, $num, $init, $printed_name, $arg, $ntype, $argoff, $subtype) = @{$other}{qw(var type num init printed_name arg ntype argoff subtype)};
    my %p;

    no warnings 'uninitialized';
    my $rv = eval $code;
    die "Error evaling typemap: $@\nTypemap code was:\n$code" if $@;
    return $rv;
}

package
    ExtUtils::Typemaps; # hide from pause
use strict;
use warnings;

my ($orig_merge, $orig_parse);

BEGIN {
    $orig_merge = \&merge;
    $orig_parse = \&_parse;
    no strict 'refs';
    delete ${__PACKAGE__.'::'}{merge};
    delete ${__PACKAGE__.'::'}{_parse};
}


sub merge {
    local $Panda::Install::ParseXS::top_typemaps = $_[0];
    return $orig_merge->(@_);
}

sub _parse {
    local $Panda::Install::ParseXS::cur_typemaps = $_[0];
    return $orig_parse->(@_);
}

package
    ExtUtils::Typemaps::OutputMap; # hide from pause
use strict;
use warnings;

my $orig_onew;
BEGIN {
    $orig_onew = \&new;
    no strict 'refs';
    delete ${__PACKAGE__.'::'}{new};
}

sub new {
    my $proto = shift;
    my $self = $orig_onew->($proto, @_);
    Panda::Install::ParseXS::map_postprocess($self) unless ref $proto; # if $proto is object, it's cloning, no need to postprocess
    return $self;
};

package
    ExtUtils::Typemaps::InputMap; # hide from pause
use strict;
use warnings;

my $orig_inew;
BEGIN {
    $orig_inew = \&new;
    no strict 'refs';
    delete ${__PACKAGE__.'::'}{new};
}

sub new {
    my $proto = shift;
    my $self = $orig_inew->($proto, @_);
    Panda::Install::ParseXS::map_postprocess($self) unless ref $proto; # if $proto is object, it's cloning, no need to postprocess
    return $self;
};

package
    ExtUtils::ParseXS::Utilities; # hide from pause
use strict;
use warnings;
no warnings 'redefine';

# remove ugly default behaviour, it always overrides typemaps in xsubpp's command line
sub standard_typemap_locations {
    my $inc = shift;
    my @ret;
    push @ret , 'typemap' if -e 'typemap';
    return @ret;
}

=head1 AUTHOR

Pronin Oleg <syber@crazypanda.ru>, Crazy Panda, CP Decision LTD

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
