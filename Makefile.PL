use strict;
use warnings;

use ExtUtils::MakeMaker;

&WriteMakefile(
    NAME          => "IO::EventMux",
    AUTHOR        => 'Jonas Jensen <jonas@infopro.dk>, Troels Liebe Bentsen <troels@infopro.dk>',
    VERSION_FROM  => 'IO/EventMux.pm',
    ABSTRACT_FROM => 'IO/EventMux.pm',
    PL_FILES      => {},
    dist          => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
);
