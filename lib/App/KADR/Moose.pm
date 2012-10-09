package App::KADR::Moose;
use v5.14;
use Hook::AfterRuntime;
use Moose ();
use Moose::Exporter ();
use MooseX::Attribute::Chained ();
use namespace::autoclean;
use true;

use common::sense;

my $FEATURE_VERSION = ':14';

my ($moose_import) = Moose::Exporter->setup_import_methods(
	with_meta => [qw(has)],
	also => [qw(Moose)],
	install => [qw(unimport init_meta)],
);

sub has($;@) {
	my $meta = shift;
	my $name = shift;

	Moose->throw_error('Usage: has \'name\' => ( key => value, ... )')
		if @_ % 2 == 1;

	my %options = (definition_context => Moose::Util::_caller_info(), @_);
	my $attrs = ref $name eq 'ARRAY' ? $name : [$name];

	$options{is} //= 'rw';
	$options{traits} //= [];
	push @{$options{traits}}, 'Chained' unless $options{traits} ~~ 'Chained';

	$meta->add_attribute($_, %options) for @$attrs;
}

sub import {
	my $self = shift;

	Moose->throw_error('Usage: use ' . __PACKAGE__ . ' (key => value, ...)')
		if @_ % 2 == 1 && ref $_[0] ne 'HASH';

	my $opts = @_ == 1 ? shift : {@_};
	my $into = $opts->{into} ||= scalar caller;
	my $mutable = delete $opts->{mutable};

	$self->$moose_import($opts);

	# use common::sense
	strict->unimport;
	warnings->unimport;
	common::sense->import;

	# Require a perl version.
	feature->import($FEATURE_VERSION);

	# Cleanliness
	namespace::autoclean->import(-cleanee => $into);
	$into->true::import;

	unless ($mutable) {
		after_runtime {
			$into->meta->make_immutable;
		};
	}
}
