#! /usr/bin/env perl

use Module::Build;

my $build = Module::Build->new(
	module_name => "App::KADR",
	license => "open_source",
	dist_abstract => "Kulag's AniDB Renamer",
	dist_version => 1,
	dist_author => 'Kulag <g.kulag@gmail.com>',
	script_files => "kadr.pl",
	requires => {
		"perl" => "5.14.0",
		"Class::Load" => "0",
		"common::sense" => "0",
		'Const::Fast' => 0,
		"DBD::SQLite" => "0",
		"DBI" => "0",
		"Digest::ED2K" => "0",
		"Digest::MD4" => "0",
		"enum" => "0",
		"Expect" => "0",
		"File::Copy" => "0",
		'File::HomeDir' => 0,
		"File::Find" => "0",
		"File::Spec::Memoized" => "0",
		'Guard' => 0,
		'Hook::AfterRuntime' => 0,
		"List::AllUtils" => "0",
		'Mojo::EventEmitter' => 0,
		"Moose" => "0",
		'Moose::Exporter' => 0,
		'MooseX::Attribute::Chained' => 0,
		"MooseX::Getopt" => "0",
		'MooseX::NonMoose' => 0,
		"MooseX::SimpleConfig" => "0",
		'MooseX::StrictConstructor' => 0,
		'MooseX::Types::LoadableClass' => 0,
		'MooseX::Types::Moose' => 0,
		"MooseX::Types::Stringlike" => "0",
		'namespace::autoclean' => 0,
		"Text::Xslate" => "0",
		'Sub::Exporter' => 0,
		'true::VERSION' => 0,
		"YAML::XS" => "0",
	},
	configure_requires => {
		'Test::More' => 0,
		'Test::Exception' => 0,
	},
	meta_merge => {
		resources => {
			license => 'http://opensource.org/licenses/ISC',
			repository => 'https://github.com/Kulag/KADR',
		},
	},
	share_dir => 'share',
);

$build->create_build_script;
