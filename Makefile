all: temptest

temptest:
	@for i in t/*; do echo $$i;perl -w $$i; done

test:
	@perl -e 'use Test::Harness qw(&runtests); runtests @ARGV' t/*.t
