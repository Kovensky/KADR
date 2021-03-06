package App::KADR::Path::File;
use Moose;

use App::KADR::Path::Dir;

extends 'Path::Class::File', 'App::KADR::Path::Entity';

my %cache;

sub dir_class() { 'App::KADR::Path::Dir' }

sub has_dir { defined $_[0]{dir} }

sub is_absolute {
	$_[0]->{is_absolute} //= $_[0]->SUPER::is_absolute;
}

sub is_hidden {
	$_[0]{file} =~ /^\./;
}

sub new {
	my $class = shift;
	my ($volume, $file_dirs, $base) = $class->_spec->splitpath(pop);

	# Dir
	my $dir
		= $file_dirs                        ? $class->dir_class->new(@_, $file_dirs)
		: @_ == 1 && ref $_[0] eq dir_class ? $_[0]
		: @_                                ? $class->dir_class->new(@_)
		:                                     ();

	# Check for cached file
	$cache{$dir || '.'}->{$base} //= do {
		my $self = $class->Path::Class::Entity::new;

		$self->{dir}  = $dir;
		$self->{file} = $base;

		$self;
	};
}

sub relative {
	my $self = shift;
	@_
		? $self->SUPER::relative(@_)
		: $self->{_relative}{$self->_spec->curdir} //= $self->SUPER::relative;
}

sub stringify {
	$_[0]->{_stringify} //= $_[0]->SUPER::stringify;
}

__PACKAGE__->meta->make_immutable(inline_constructor => 0);

=head1 NAME

L<App::KADR::Path::File> - like L<Path::Class::File>, but faster

=head1 DESCRIPTION

L<App::KADR::Path::File> is an optimized and memoized subclass of
L<Path::Class::File>. Identical logical paths use the same instance for
performance.

=head1 METHODS

L<App::KADR::Path::File> inherits all methods from L<Path::Class::File> and
L<App::KADR::Path::Entity> and implements the following new ones.

=head2 C<new>

	my $file = App::KADR::Path::File->new('/home', ...);
	my $file = file('/home', ...);

Turn a path into a file. This static method is memoized.

=head2 C<dir_class>

	my $dir_class = $file->dir_class;

Dir class in use by this file.

=head2 C<is_absolute>

	my $is_absolute = $file->is_absolute;

Check if file is absolute. This method is memoized.

=head2 C<is_hidden>

	my $is_hidden = $file->is_hidden;

Check if file is hidden.

=head2 C<relative>

	my $relative_file = $file->relative;
	my $relative_file = $file->relative('..');

Turn file into a file relative to another dir.
The other dir defaults to the current directory.

=head2 C<stringify>

	my $string = $file->stringify;
	my $string = $file . '';

Turn file into a string. This method is memoized.

=head1 SEE ALSO

	L<App::KADR::Path::Dir>, L<App::KADR::Path::Entity>, and L<Path::Class::File>
