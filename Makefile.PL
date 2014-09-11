use strict;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME          => "Panda::Install",
    ABSTRACT_FROM => "lib/Panda/Install.pm",
    VERSION_FROM  => "lib/Panda/Install.pm",
    TEST_REQUIRES => {'Test::Deep' => 0},
);