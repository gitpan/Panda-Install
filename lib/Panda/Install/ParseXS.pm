package Panda::Install::ParseXS;
use strict;
use warnings;
use feature 'state';
use ExtUtils::ParseXS;
use ExtUtils::ParseXS::Eval;
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
    
    if ($map->{xstype} =~ s/^(.+?)\s+:\s+([^()]+)(?:\(([^()]*)\))?$/$1/) {
        my $parent_xstype = $2;
        my $parent_params = $3;
        my $parent_map = $is_output ? outmap($parent_xstype) : inmap($parent_xstype);
        die "\e[31m No parent $parent_xstype found in $type map \e[0m" unless $parent_map;
        my $parent_code = $parent_map->code;
        
        if ($parent_params and $parent_code) {
            my @pairs = split /\s*,\s*/, $parent_params;
            foreach my $pair (@pairs) {
                my ($k,$v) = split /\s*=\s*/, $pair;
                $parent_code = "    \${ \$p{'$k'} = '$v'; \\''; }\n$parent_code";
            }
        }
        
        if ($is_output) {
            $code .= "\n" if $code;
            $code .= $parent_code;
        } else {
            my $prevcode = $code;
            $code = $parent_code;
            $code .= "\n$prevcode" if $prevcode;
        }
    }
        
    if ($is_output) {
        # if code has '$arg = <something>' not in first line - prevent fuckin ExtUtils::ParseXS from adding '$arg = sv_newmortal()'
        # triggered by $arg = NULL which must firstly be set by typemap itself. Move it on top if inheriting
        #state $ppline = '    $arg = $arg; /* suppress xsubpp\'s pollution of $arg */';
        my $found = ($code =~ s/^\s*\$arg\s*=\s*NULL\s*;\s*$//gm); # remove previous guardians;
        $code = "    \$arg = NULL;\n$code" if $found;
        $code =~ s/\n\s*\n/\n/gm;
    }
    
#    if ($code =~ /xs/) {
#        warn "--------------------";
#        warn $code;
#        warn "--------------------";
#    }
    $map->code($code);
}

sub outmap { return $cur_typemaps->get_outputmap(xstype => $_[0]) || $top_typemaps->get_outputmap(xstype => $_[0]); }
sub inmap  { return $cur_typemaps->get_inputmap(xstype => $_[0]) || $top_typemaps->get_inputmap(xstype => $_[0]); }

package ExtUtils::ParseXS;
use strict;
use warnings;

my $orig_fetch_para;

BEGIN {
    $orig_fetch_para = \&fetch_para;
    no strict 'refs';
    delete ${__PACKAGE__.'::'}{fetch_para};
    delete ${__PACKAGE__.'::'}{eval_output_typemap_code};
    delete ${__PACKAGE__.'::'}{eval_input_typemap_code};
}

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
        $lines->[0] = $type;
        
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
        if ($lines->[-1] =~ /^\}/) { pop @$lines; pop @$linno; }
    }

    my $para = join("\n", @$lines);
    
    if ($para =~ /^CODE\s*:/m and $para !~ /^OUTPUT\s*:/m) {
        push @$lines, 'OUTPUT:', '    RETVAL';
        push @$linno, $linno->[-1]+1 for 1..2;
        $para = join("\n", @$lines);
    }
    
    return $ret;
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

package ExtUtils::Typemaps;
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

package ExtUtils::Typemaps::OutputMap;
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

package ExtUtils::Typemaps::InputMap;
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


=head1 AUTHOR

Pronin Oleg <syber@crazypanda.ru>, Crazy Panda, CP Decision LTD

=head1 LICENSE

You may distribute this code under the same terms as Perl itself.

=cut

1;
