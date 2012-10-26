#!/usr/bin/env perl

use common::sense;
use Test::More tests => 8;

require_ok 'App::KADR::AniDB::UDP::Client::Caching';

my %testhash = (
	a => "some string",
	b => "anidb'style'array",
	c => "anidb`style`apostrophes",
	d => [ "an`arrayref" ],
	e => { f => "a`hashref" },
	g => bless {},
);

App::KADR::AniDB::UDP::Client::Caching::anidb_string_fix(\%testhash);

is $testhash{a},      "some string",             'keeps unrelated strings intact';
# Yes, I am aware this introduces ambiguity;
# there is currently no way to sanely consume arrays in KADR anyway
is $testhash{b},      "anidb'style'array",       'does not modify anidb arrays';
is $testhash{c},      "anidb'style'apostrophes", 'does repair `-apostrophes into real ones';
is ref $testhash{d},  "ARRAY",                   'keeps references intact';
is $testhash{d}->[0], "an'arrayref",             'recursively applies to arrayrefs';
is $testhash{e}->{f}, "a'hashref",               'recursively applies to hashrefs';
ok ref $testhash{g},                             'keeps other references intact';
