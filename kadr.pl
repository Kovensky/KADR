#!/usr/bin/env perl
# Copyright (c) 2009, Kulag <g.kulag@gmail.com>
#
# Permission to use, copy, modify, and/or distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
# KADR was forked from ADBREN v4 Copyright (c) 2008, clip9 <clip9str@gmail.com>

use v5.14;
use common::sense;
use open qw(:std :utf8);
use utf8;
use Date::Format;
use DBI::SpeedySimple;
use Digest::ED2K;
use Encode;
use Expect;
use File::Copy;
use File::Find;
use FindBin;
use Guard;
use List::AllUtils qw(first none);
use POSIX ();
use Text::Xslate;
use Time::HiRes;
use Unicode::Normalize;

use lib "$FindBin::RealBin/lib";
use App::KADR::AniDB::UDP::Client;
use App::KADR::Config;
use App::KADR::Path -all;
use App::KADR::Term::StatusLine::Fractional;
use App::KADR::Term::StatusLine::Freeform;
use App::KADR::Util qw(:pathname_filter shortest);

use constant TERM_SPEED       => $ENV{KADR_TERM_SPEED}       // 0.05;
use constant MTIME_DIFF_LIMIT => $ENV{KADR_MTIME_DIFF_LIMIT} // 10;
use constant EMPTY_ED2K       => "31d6cfe0d16ae931b73c59d7e0c089c0";

scope_guard \&cleanup;
$SIG{INT} = \&cleanup;

STDOUT->autoflush(1);

my $conf = App::KADR::Config->new_with_options;

# A cache to speed up in_list calls.
my $in_list_cache = {};

my $db = DBI::SpeedySimple->new($conf->database);
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS known_files (`filename` TEXT, `size` INT, `ed2k` TEXT PRIMARY KEY, `mtime` INT, `avdumped` INT);}) and
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS episode (`eid` INTEGER PRIMARY KEY, `aid` INT, `length` INT, `rating` INT,
                 `vote_count` INT, `number` VARCHAR(10), `english_name` TEXT, `romaji_name` TEXT, `kanji_name` TEXT,
                 `air_date` INT, `updated` INT);}) and
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS anime (`aid` INTEGER PRIMARY KEY, `dateflags` INT, `year` VARCHAR(10), `type` VARCHAR(20),
                 `romaji_name` TEXT, `kanji_name` TEXT, `english_name` TEXT, `total_episodes` INT, `highest_episode_number` INT,
                 `air_date` INT, `end_date` INT, `rating` VARCHAR(4), `rating_votes` INT, `temp_rating` VARCHAR(4), `temp_rating_votes` INT,
                 `review_rating` VARCHAR(4), `review_count` INT, `is_r18` INT, `special_episode_count` INT, `credits_episode_count` INT,
                 `other_episode_count` INT, `trailer_episode_count` INT, `parody_episode_count` INT, `updated` INT);}) and
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS anidb_mylist_file (`lid` INT, `fid` INTEGER PRIMARY KEY, `eid` INT, `aid` INT, `gid` INT,
				 `date` INT, `state` INT, `viewdate` INT, `storage` TEXT, `source` TEXT, `other` TEXT, `filestate` TEXT, `updated` INT);}) and
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS anidb_mylist_anime (`aid` INTEGER PRIMARY KEY, `anime_title` TEXT, `episodes` INT,
				 `eps_with_state_unknown` TEXT, `eps_with_state_on_hdd` TEXT, `eps_with_state_on_cd` TEXT, `eps_with_state_deleted` TEXT,
				 `watched_eps` TEXT, `updated` INT);}) and
$db->{dbh}->do(q{CREATE TABLE IF NOT EXISTS adbcache_file (`fid` INTEGER PRIMARY KEY, `aid` INT, `eid` INT, `gid` INT, `lid` INT,
				 `other_episodes` TEXT, `is_deprecated` INT, `status` INT, `size` INT, `ed2k` TEXT, `md5` TEXT, `sha1` TEXT, `crc32` TEXT,
				 `quality` TEXT, `source` TEXT, `audio_codec` TEXT, `audio_bitrate` INT, `video_codec` TEXT, `video_bitrate` INT, `video_resolution` TEXT,
				 `file_type` TEXT, `dub_language` TEXT, `sub_language` TEXT, `length` INT, `description` TEXT, `air_date` INT,
				 `group_name` TEXT, `group_short_name` TEXT, `updated` INT)}) or die "Could not initialize the database";

if ($conf->expire_cache) {
	$db->{dbh}->do('DELETE FROM adbcache_file WHERE updated < ' . (time - $conf->cache_timeout_file));
	$db->{dbh}->do('DELETE FROM anime WHERE updated < ' . (time - $conf->cache_timeout_anime));
	$db->{dbh}->do('DELETE FROM episode WHERE updated < ' . (time - $conf->cache_timeout_episode));
	$db->{dbh}->do('DELETE FROM anidb_mylist_anime WHERE updated < ' . (time - $conf->cache_timeout_mylist_unwatched) . ' AND watched_eps != eps_with_state_on_hdd');
	$db->{dbh}->do('DELETE FROM anidb_mylist_anime WHERE updated < ' . (time - $conf->cache_timeout_mylist_watched) . ' AND watched_eps = eps_with_state_on_hdd');
}

if($conf->load_local_cache_into_memory) {
	$db->cache([
		{table => 'known_files', indices => ['filename', 'size', 'mtime']},
		{table => 'anime', indices => ['aid']},
		{table => 'episode', indices => ['eid']},
		{table => 'episode', indices => ['aid', 'number']},
		{table => 'adbcache_file', indices => ['ed2k', 'size']},
		{table => 'anidb_mylist_file', indices => ['lid']},
		{table => 'anidb_mylist_anime', indices => ['aid']},
	]);
}

my $a;
unless ($conf->hash_only) {
	$a = App::KADR::AniDB::UDP::Client->new({
		username => $conf->anidb_username,
		password => $conf->anidb_password,
		time_to_sleep_when_busy => $conf->time_to_sleep_when_busy,
		max_attempts => $conf->query_attempts,
		timeout => $conf->query_timeout,
	});
}

# Path template.
my $pathname_filter
	= $conf->windows_compatible_filenames
	? \&pathname_filter_windows
	: \&pathname_filter;
my $tx = Text::Xslate->new(
	function => {html_escape => $pathname_filter},
	path => {'path.tx' => $conf->file_naming_scheme},
);

my @files = find_files(@{$conf->dirs_to_scan});

print 'Sorting... ';
@files = $conf->collator->(@files);
say 'done.';

my @ed2k_of_processed_files;
my $current_file;
my $sl = App::KADR::Term::StatusLine::Fractional->new(
	max => scalar @files,
	update_label => sub { NFC(shortest $current_file->relative, $current_file) },
);

for my $file (@files) {
	$sl->incr;
	$current_file = $file;
	$sl->update_term if $sl->last_update + TERM_SPEED < Time::HiRes::time;

	next unless $file->is_file_exists;

	my $file_size = $file->size;
	my $mtime     = $file->stat->mtime;
	if (time() - $mtime < MTIME_DIFF_LIMIT) {
		$sl->child('Freeform')->finalize('Being Modified');
		next;
	}
	push @ed2k_of_processed_files, my $ed2k = ed2k_hash($file, $file_size, $mtime);
	process_file($file, $ed2k, $file_size) unless $conf->hash_only;
}
$sl->finalize;

if ($conf->update_anidb_records_for_deleted_files && !$conf->hash_only) {
	update_mylist_state_for_missing_files(\@ed2k_of_processed_files, $a->MYLIST_STATE_DELETED);
}

if (!$conf->test && $conf->delete_empty_dirs_in_scanned) {
	print "Deleting empty folders in those scanned... ";

	my @scan_dirs = @{$conf->dirs_to_scan};
	my %keep;
	@keep{ @scan_dirs } = ();

	finddepth({
		follow => 1,
		no_chdir => 1,
		wanted => sub { rmdir unless exists $keep{$_} },
	}, @scan_dirs);

	say "done.";
}

sub valid_file {
	return if substr($_->basename, -5) eq '.part';
	return if substr($_->basename, 0, 1) eq '.';
	return if $_->basename eq 'Thumbs.db';
	return if $_->basename eq 'desktop.ini';
	1;
}

sub find_files {
	my @dirs = @_;
	my @files;

	my $sl = App::KADR::Term::StatusLine::Fractional->new(label => 'Scanning Directory', max => \@dirs);
	for my $dir (@dirs) {
		$sl->incr;
		if ($sl->last_update + TERM_SPEED < Time::HiRes::time) {
			$sl->update(shortest $dir->relative, $dir);
		}

		for ($dir->children) {
			if ($_->is_dir) { push @dirs, $_ }
			else {
				push @files, $_ if valid_file
			}
		}
	}

	$sl->log(sprintf 'Found %d files in %d directories.', scalar @files, scalar @dirs);

	@files;
}

sub process_file {
	my ($file, $ed2k, $file_size) = @_;
	my $fileinfo = file_query(ed2k => $ed2k, size => $file_size);

	# File not in AniDB.
	unless ($fileinfo) {
		$sl->child('Freeform')->finalize('Ignored');
		$db->remove('known_files', {ed2k => $ed2k, size => $file_size});
		return;
	}

	$fileinfo->{anime} = anime_query(aid => $fileinfo->{aid});
	$fileinfo->{episode} = episode_query(eid => $fileinfo->{eid});

	# Auto-add to mylist.
	my $mylistinfo = mylist_file_query($fileinfo->{lid} ? (lid => $fileinfo->{lid}) : (fid => $fileinfo->{fid}));
	if(!defined $mylistinfo && !$conf->test) {
		my $proc_sl = $sl->child('Freeform')->update('Adding to AniDB Mylist');
		if(my $lid = $a->mylist_add(fid => $fileinfo->{fid}, state => $a->MYLIST_STATE_HDD)) {
			$db->remove('anidb_mylist_anime', {aid => $fileinfo->{aid}}); # Force an update of this record, it's out of date.
			$db->update('adbcache_file', {lid => $lid}, {fid => $fileinfo->{fid}});
			$proc_sl->finalize_and_log('Added to AniDB Mylist');
		}
		else {
			$proc_sl->finalize_and_log('Error adding to AniDB Mylist');
		}
	}
	elsif($mylistinfo->{state} != $a->MYLIST_STATE_HDD && !$conf->test) {
		my $proc_sl = $sl->child('Freeform')->update('Setting AniDB Mylist state to "On HDD"');
		if($a->mylistedit({lid => $fileinfo->{lid}, state => $a->MYLIST_STATE_HDD})) {
			$db->update('anidb_mylist_file', {state => $a->MYLIST_STATE_HDD}, {fid => $mylistinfo->{fid}});
			$proc_sl->finalize_and_log('Set AniDB Mylist state to "On HDD"');
		}
		else {
			$proc_sl->finalize_and_log('Error setting AniDB Mylist state to "On HDD"');
		}
	}

	my $mylistanimeinfo = mylist_anime_query(aid => $fileinfo->{aid});
	if(!in_list($fileinfo->{episode}->{number}, $mylistanimeinfo->{eps_with_state_on_hdd})) {
		# Our mylistanime record is old. Can happen if the file was not added by kadr.
		$db->remove('anidb_mylist_anime', {aid => $fileinfo->{aid}});
		$mylistanimeinfo = mylist_anime_query(aid => $fileinfo->{aid});
	}

	$fileinfo->{episode}->{watched} = in_list($fileinfo->{episode}->{number}, $mylistanimeinfo->{watched_eps});

	# Watched / Unwatched directories.
	my $dir = first { $_->subsumes($file) } @{$conf->dirs_to_scan};
	if ($fileinfo->{episode}->{watched}) {
		if (none { $_->subsumes($dir) } @{$conf->valid_dirs_for_watched_eps}) {
			$dir = $conf->dir_to_put_watched_eps;
		}
	}
	else {
		if (none { $_->subsumes($dir) } @{$conf->valid_dirs_for_unwatched_eps}) {
			$dir = $conf->dir_to_put_unwatched_eps;
		}
	}

	my %season = date_to_season($fileinfo->{anime}->{air_date});
	foreach (keys %season) {
		$fileinfo->{anime}->{$_} = $season{$_}
	}

	$fileinfo->{video_codec} =~ s/H264\/AVC/H.264/g;
	$fileinfo->{audio_codec} =~ s/Vorbis \(Ogg Vorbis\)/Vorbis/g;

	$fileinfo->{episode}->{is_special} = $fileinfo->{episode}->{number} =~ /^[PCOST]/;

	$fileinfo->{episode}->{number} =
		sprintf "\%0".length($fileinfo->{anime}->{total_episodes} || $fileinfo->{anime}->{highest_episode_number})."d",
		$fileinfo->{episode}->{number} unless $fileinfo->{episode}->{is_special};

	$fileinfo->{anime}->{is_ongoing} = !$fileinfo->{anime}->{end_date};

	# Check if this is the only episode going into the folder.
	$fileinfo->{only_episode_in_folder} =
		defined $mylistanimeinfo
		# This is the only episode from this anime on HDD.
		&& $mylistanimeinfo->{eps_with_state_on_hdd} =~ /^[a-z]*\d+$/i
		# And this is it.
		&& $fileinfo->{episode}->{number} eq $mylistanimeinfo->{eps_with_state_on_hdd}
		&& (
			# This episode is the only watched episode from this anime.
			($fileinfo->{episode}->{watched} && $fileinfo->{episode}->{number} eq $mylistanimeinfo->{watched_eps})
			# Or this episode is the only unwatched episode from this anime.
			|| (!$fileinfo->{episode}->{watched} && count_list($mylistanimeinfo->{eps_with_state_on_hdd}) - count_list($mylistanimeinfo->{watched_eps}) == 1)
		);

	$fileinfo->{is_primary_episode} =
		# This is the only episode.
		int($fileinfo->{anime}->{total_episodes}) == 1 && int($fileinfo->{episode}->{number}) == 1
		# And this file contains the entire episode.
		&& !$fileinfo->{other_episodes}
		# And it has a generic episode name.
		# Usually equal to the anime type except for movies where multiple episodes may exist for split releases.
		&& ($fileinfo->{episode}->{english_name} eq $fileinfo->{anime}->{type} || $fileinfo->{episode}->{english_name} eq 'Complete Movie');

	$fileinfo->{file_version} = $a->file_version($fileinfo);

	my $newname = file( $tx->render('path.tx', $fileinfo) =~ s{[\r\n]}{}gr );

	# We can't end file/dir names in a dot on windows.
	if ($conf->windows_compatible_filenames) {
		$newname = file(
			map { s{\.$}{}r }
			($newname->has_dir ? $newname->dir->dir_list : ()),
			$newname->basename
		);
	}

	$newname = NFD($newname) if $^O eq 'darwin';

	move_file($file, $ed2k, $dir->file($newname));
}

sub move_file {
	my ($old, $ed2k, $new) = @_;

	# Doesn't need to be renamed.
	return if $old eq $new || $old->absolute eq $new->absolute;

	$new->dir->mkpath unless -e $new->dir;

	my $display_new = NFC(shortest($new->relative, $new));
	my $sl = $sl->child('Freeform');

	if (-e $new) {
		$sl->finalize('Would overwrite existing file: ' . $display_new);
		return;
	}

	if ($conf->test) {
		$sl->finalize('Would have moved to: ' . $display_new);
		return;
	}

	$sl->update('Moving to ' . $display_new);
	if (move($old, $new)) {
		$db->update('known_files', {filename => NFC($new->basename)}, {ed2k => $ed2k, size => -s $new});
		$sl->finalize('Moved to ' . $display_new);
	}
	else {
		my $name_max = POSIX::pathconf($new->dir, POSIX::_PC_NAME_MAX);
		if ($name_max < length $new->basename) {
			$sl->finalize('File name exceeds maximum length for folder (' . $name_max . '): ' . $display_new);
		}
		else {
			$sl->finalize('Error moving to ' . $display_new);
			exit 2;
		}
	}
}

sub avdump {
	my($file, $size, $mtime, $ed2k) = @_;
	my($aved2k, $timedout);
	my $avsl = $sl->child('Fractional', label => 'AvHashing', format => 'percent', max => 100);
	(my $esc_file = $file) =~ s/(["`])/\\\$1/g;
	my $exp = Expect->new($conf->avdump . " -vas -tout:20:6555 \"$esc_file\" 2>&1");
	$exp->log_stdout(0);
	$exp->expect($conf->avdump_timeout,
		[qr/H\s+(\d+).(\d{2})/, sub {
			my @m = @{shift->matchlist};
			$avsl->update(int(int($m[0]) + int($m[1]) / 100));
			exp_continue;
		}],
		[qr/P\s+(\d+).(\d{2})/, sub {
			my @m = @{shift->matchlist};
			if($avsl->label eq 'AvHashing') {
				$avsl->label('AvParsing');
			}
			$avsl->update(int(int($m[0]) + int($m[1]) / 100));
			exp_continue;
		}],
		[qr/ed2k: ([0-9a-f]{32})/, sub {
			my @m = @{shift->matchlist};
			$aved2k = $m[0];
			exp_continue;
		}],
		timeout => sub { $timedout = 1; }
	);
	if($timedout) {
		$avsl->finalize;
		return avdump($file, $size, $ed2k);
	}
	if(!$aved2k) {
		$avsl->log('Error avdumping.');
		exit 2;
	}
	$avsl->finalize_and_log('Avdumped');
	if($ed2k) {
		 $db->update('known_files', {avdumped => 1}, {ed2k => $ed2k, size => $size});
	}
	else {
		my $file_sn = substr($file, rindex($file, '/') + 1, length($file));
		$db->set('known_files', {avdumped => 1, ed2k => $aved2k, filename => NFC($file_sn), size => $size, mtime => $mtime},
			{filename => NFC($file_sn), size => $size});
		return $aved2k;
	}
}

sub ed2k_hash {
	my($file, $size, $mtime) = @_;

	return EMPTY_ED2K unless $size;

	if(my $r = $db->fetch('known_files', ['ed2k', 'avdumped'],
		{filename => NFC($file->basename), size => $size, mtime => $mtime}, 1)) {
		avdump($file, $size, $mtime, $r->{ed2k}) if $conf->has_avdump and !$r->{avdumped};
		return $r->{ed2k};
	}

	if($conf->has_avdump && !$conf->hash_only) {
		return avdump($file, $size, $mtime);
	}

	my $ctx = Digest::ED2K->new;
	my $fh = $file->open('<:raw');
	my $ed2k_sl = $sl->child('Fractional', label => 'Hashing', max => $size, format => 'percent');

	while (my $bytes_read = $fh->read(my $buffer, 4096)) {
		$ctx->add($buffer);
		$ed2k_sl->incr($bytes_read);
		$ed2k_sl->update_term if $ed2k_sl->last_update + TERM_SPEED < Time::HiRes::time;
	}

	$ed2k_sl->finalize('Hashed');

	my $ed2k = $ctx->hexdigest;
	if($db->exists('known_files', {ed2k => $ed2k, size => $size})) {
		$db->update('known_files', {filename => NFC($file->basename), mtime => $mtime}, {ed2k => $ed2k, size => $size});
	}
	else {
		$db->insert('known_files', {ed2k => $ed2k, filename => NFC($file->basename), size => $size, mtime => $mtime});
	}

	return $ed2k;
}

# Determines if the specified number is in a AniDB style list of episode numbers.
# Example: in_list(2, "1-3") == true
sub in_list {
	my($needle, $haystack) = @_;
	cache_list($haystack);
	if($needle =~ /^(.+),(.+)$/) {
		return in_list($1, $haystack);
	}
	if($needle =~ /^(\w+)-(\w+)$/) {
		return in_list($1, $haystack);
		# This is commented out to work around a bug in the AniDB UDP API.
		# For multi-episode files, the API only includes the first number in the lists that come in MYLIST commands.
		#for ($first..$last) {
		#	return 0 if !in_list($_, $haystack);
		#}
		#return 1;
	}
	return defined $in_list_cache->{$haystack}->{(int($needle) || $needle)};
}

sub count_list {
	my ($list) = @_;
	cache_list($list);
	return scalar(keys(%{$in_list_cache->{$list}}));
}

sub cache_list {
	my($list) = @_;
	if(!defined $in_list_cache->{$list}) {
		for(split /,/, $list) {
			if($_ =~ /^(\w+)-(\w+)$/) {
				for my $a (range($1, $2)) {
					$in_list_cache->{$list}->{$a} = 1;
				}
			} else {
				$in_list_cache->{$list}->{(int($_) || $_)} = 1;
			}
		}
	}
}

sub range {
	my($start, $end) = @_;
	$start =~ s/^([a-xA-Z]*)(\d+)$/$2/;
	my $tag = $1;
	$end =~ s/^([a-xA-Z]*)(\d+)$/$2/;
	map { "$tag$_" } $start .. $end;
}

sub cleanup {
	$a->logout if $a;
	$db->{dbh}->disconnect if $db;
	exit;
}

sub update_mylist_state_for_missing_files {
	my ($have_files, $set_state) = @_;
	$set_state //= $a->MYLIST_STATE_DELETED;
	my $set_state_name = $a->mylist_state_name_for($set_state);

	# Missing files.
	# Would need to bind/interpolate too many values to "NOT IN ()", this is faster.
	my $all_files = $db->{dbh}->selectall_arrayref('SELECT ed2k, size, filename FROM known_files');
	my %have_files;
	@have_files{ @$have_files } = ();
	my @missing_files
		= $conf->collator->(sub { $_[0][2] },
			grep { !exists $have_files{$_->[0]} } @$all_files
		);

	# Don't print if no missing files.
	return unless @missing_files;

	$sl = App::KADR::Term::StatusLine::Fractional->new(
		label => 'Missing File',
		max => scalar @missing_files,
	);

	for my $file (@missing_files) {
		my ($ed2k, $size, $name) = @$file;

		# Forget file regardless of other processing.
		scope_guard {
			return if $conf->test;
			$db->remove('known_files', {ed2k => $ed2k, size => $size});
		};

		$sl->incr->update(NFC($name));

		# File mylist information.
		my $lid = get_cached_lid(ed2k => $ed2k, size => $size);
		my $mylist_file;
		if ($lid) {
			# Update mylist record so we don't overwrite a user-set state.
			$db->remove('anidb_mylist_file', {lid => $lid});
			$mylist_file = mylist_file_query(lid => $lid);
		}
		else {
			# Not in cache.
			$mylist_file = mylist_file_query(ed2k => $ed2k, size => $size);
			$lid = $mylist_file->{lid} if $mylist_file;
		}

		# File not in mylist.
		next unless $mylist_file;

		# Don't overwrite user-set status.
		unless ($mylist_file->{state} == $a->MYLIST_STATE_HDD) {
			$sl->child('Freeform')
				->finalize('AniDB Mylist status already set.');
			next;
		}

		my $update_sl
			= $sl->child('Freeform')
				->update('Setting mylist state to ' . $set_state_name);

		next if $conf->test;

		# Try to edit
		$a->mylist_add(edit => 1, lid => $lid, state => $set_state)
			or die 'Error setting mylist state';

		$update_sl->finalize('Mylist state set to ' . $set_state_name);
		$db->update('anidb_mylist_file', {state => $set_state}, {lid => $lid});
	}
}

sub date_to_season {
	my ($timestamp) = @_;

	return () unless $timestamp;

	# This is meant to be applied to the first air date
	# Sometimes shows start airing a few weeks before their
	# designated season so some leeway should be allowed.
	# These quarters roughly correspond to syoboi's.
	my @quarter_map = (
		0, 1, 1, # 0th month, Jan, Feb
		2, 2, 2, # March, April, May
		3, 3, 3, # June, July, Aug
		4, 4, 4, # Sept, Oct, Nov,
		1        # Dec counts as 1st quarter of next year
	);
	# Each quarter corresponds to a season
	my @season_map = qw{0 Winter Spring Summer Autumn};

	my ($yr, $mo) = split /-/, time2str('%Y-%m', $timestamp, "UTC");;
	$yr += 1 if $mo == 12; # We consider December as Winter of next year
	return (
		season_year    => $yr,
		season_quarter => $quarter_map[$mo],
		season         => $season_map[$quarter_map[$mo]],
	);
}

sub file_query {
	my %params = @_;
	my $r;

	# Cached
	return $r if $r = $db->fetch("adbcache_file", ["*"], \%params, 1);

	# Update
	my $file_sl = $sl->child('Freeform')->update('Updating file information');
	$r = eval { $a->file(%params) };

	# Due to unconfigurable fieldlists, the response is occasionally too long,
	# and gets truncated by the server after compression.
	if ($@) {
		die unless $@ =~ /^Error inflating response/;
		$file_sl->finalize($@);
	}

	return unless $r;

	# Temporary fix to make strings look nice because AniDB::UDP::Client doesn't understand types.
	$r->{$_} =~ tr/`/'/ for keys %$r;

	# Cache
	$r->{updated} = time;
	$db->set('adbcache_file', $r, {fid => $r->{fid}});

	$r;
}

sub anime_query {
	my %params = @_;
	my $r = $db->fetch('anime', ['*'], \%params, 1);
	return $r if $r;

	my $am_sl = $sl->child('Freeform')->update('Updating anime information');
	$r = $a->anime(%params);
	return unless $r;

	# Temporary fix to make strings look nice because AniDB::UDP::Client doesn't understand types.
	$r->{$_} =~ tr/`/'/ for keys %$r;

	$r->{updated} = time;
	$db->set('anime', $r, {aid => $r->{aid}});
	$r;
}

sub episode_query {
	my %params = @_;
	my $r = $db->fetch('episode', ['*'], \%params, 1);
	return $r if $r;

	my $ep_sl = $sl->child('Freeform')->update('Updating episode information');
	$r = $a->episode(%params);
	return unless $r;

	# Temporary fix to make strings look nice because AniDB::UDP::Client doesn't understand types.
	$r->{$_} =~ tr/`/'/ for keys %$r;

	$r->{updated} = time;
	$db->set('episode', $r, {eid => $r->{eid}});
	$r;
}

sub get_cached_lid {
	my %params = @_;
	return unless exists $params{fid} || exists $params{ed2k};

	my $file = $db->fetch('adbcache_file', ['lid'], {size => $params{size}, ed2k => $params{ed2k}}, 1);
	$file->{lid};
}

sub mylist_file_query {
	my %params = @_;
	my $r;

	# Try to get a cached lid if passed fid / ed2k & size
	if (my $lid = get_cached_lid(%params)) {
		delete @params{qw(fid ed2k size)};
		$params{lid} = $lid;
	}

	# Cached
	if ($params{lid}) {
		return $r if $r = $db->fetch('anidb_mylist_file', ['*'], {lid => $params{lid}}, 1);
	}

	# Update
	my $ml_sl = $sl->child('Freeform')->update('Updating mylist information');
	$r = $a->mylist_file(%params);
	return unless $r;

	# Cache
	$r->{updated} = time;
	$db->set('anidb_mylist_file', $r, {lid => $r->{lid}});

	$r
}

sub mylist_anime_query {
	my %params = @_;
	my $r;

	# Cached
	return $r if $r = $db->fetch('anidb_mylist_anime', ['*'], \%params, 1);

	# Update
	my $ml_sl = $sl->child('Freeform')->update('Updating mylist anime information');
	$r = $a->mylist_anime(%params);
	return unless $r;

	if ($r->{fid}) { # 221 single mylist entry instead of the regular 312 result
		my $anime = anime_query(aid => $r->{aid});
		my $episode = episode_query(eid => $r->{eid});
		my $epno = int($episode->{number}) unless $episode->{number} =~ /[SOCTP]/;
		$r = {
			aid => $r->{aid},
			anime_title => $anime->{romaji_name},
			episodes => $anime->{total_episodes},
			eps_with_state_unknown => ($r->{state} == 0 ? $epno : ''),
			eps_with_state_on_hdd => ($r->{state} == 1 ? $epno : ''),
			eps_with_state_on_cd => ($r->{state} == 2 ? $epno : ''),
			eps_with_state_deleted => ($r->{state} == 3 ? $epno : ''),
			watched_eps => ($r->{viewdate} > 0 ? $epno : ''),
		}
	}

	# Temporary fix to make strings look nice because AniDB::UDP::Client doesn't understand types.
	$r->{$_} =~ tr/`/'/ for keys %$r;

	# Cache
	$r->{updated} = time;
	$db->set('anidb_mylist_anime', $r, {aid => $r->{aid}});

	$r
}
