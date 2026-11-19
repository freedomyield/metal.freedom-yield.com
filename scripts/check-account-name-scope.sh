#!/usr/bin/env bash
# check-account-name-scope.sh — the gate that keeps the four on-chain account names out of
# the public tree (2026-11-19 anchor-name-out design, section 7).
# CHAIN: none — reads git objects and one definition file only; touches no host, no network,
#   no broadcast, no key.
# PRIME_DIRECTIVE: TESTNET-FIRST — safe (nothing here can broadcast).
#
# The names themselves are never written anywhere: config/account-name-scope.tsv holds only
# sha256(lower-cased word) per name (the same idea as layer B of scripts/publish-guard.sh,
# whose function is copied into this gate on purpose: publish-guard.sh is PROTECTED and does
# not see paths, so it cannot say "this name is allowed in this place only").
#
# Usage:
#   check-account-name-scope.sh [--index | --messages=<base>] [-h|--help]
#     (default)           the tracked tree of HEAD (blob contents and paths)
#     --index             the staged tree (the index) instead of HEAD
#     --messages=<base>   the tree of HEAD, plus the messages of the commits <base>..HEAD
#   --index and --messages cannot be combined (exit 2).
#
# A name is found as a SUBSTRING, whatever letter case, with no word boundary: every run of
# [A-Za-z0-9_] of 3 or more bytes (binary content is cut the same way) is lower-cased and
# every part of it of 3 to 12 bytes is hashed and looked up. Where a short name lies wholly
# inside a longer name in the same word, only the longer name's role is counted (longest
# match); a short name outside it still counts for itself. Looked at: every tracked blob's content, every tracked path,
# and with --messages every commit message. A gitlink (mode 160000) is never read, only its
# path is looked at.
#
# Output (stdout) and exit codes:
#   VIOLATION <path>:<line> <role>   a name in content outside every unexpired row's glob
#   VIOLATION <path>:path <role>     a name inside a path (always, whatever the globs say)
#   VIOLATION commit:<12 hex> <role> a name in a commit message
#   EXPIRED <role> <glob> <until>    a row whose until is before today (UTC); it allows nothing
#   OBSOLETE <role> <glob>           an unexpired row whose glob matches no file containing the
#                                    name (remove it, so the list shrinks)
#   exit 0  `OK <n> files`   (or `DISABLED` when the definition says `enabled 0`)
#   exit 1  one or more of the lines above (all of them, sorted by kind)
#   exit 2  refused to judge: one reason line on stderr, no verdict on stdout — a bad
#           argument, a missing or malformed definition, a git failure, perl or Digest::SHA
#           missing, or a scan that did not print its completion mark.
# Values are never printed: a path that holds a name is shown with the word replaced by
# <role>; line contents are never shown.
#
# Fail closed: every unexpected state is exit 2 or exit 1, never a quiet pass. The perl steps
# print a fixed completion mark as their last line and this script exits 2 when it is absent,
# so a perl that died or was cut is never read as "0 findings".
#
# Definition: config/account-name-scope.tsv (ANS_CONFIG; tests use FYD_NAME_SCOPE_CONFIG).
# Today (UTC): `date -u +%Y-%m-%d`; tests use FYD_NAME_SCOPE_TODAY.
#
# Where it connects: tests/account-name-scope/test-account-name-scope.sh (picked up by
# tests/run-all-tests.sh). Nothing else refers to it. The pre-commit hook gets one
# `--index` line after the 12/7 transition. No AI step anywhere in this flow.
# How to remove it: set `enabled 0` in the definition (the gate prints DISABLED), or delete
# this file, the definition and tests/account-name-scope/; nothing else reads them.

set -u
export LC_ALL=C

ANS_CONFIG="config/account-name-scope.tsv"
ANS_NAME="check-account-name-scope"

ans_die() { echo "${ANS_NAME}: $*" >&2; exit 2; }
ans_usage() { sed -n '/^# Usage:/,/^# A name is found/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# ---- perl: the pieces shared by the three scans and the judge (one place for the word cut,
# the hash and the date rule) ---------------------------------------------------------------
IFS= read -r -d '' ANS_PERL_COMMON <<'PERLEOF' || true
use strict; use warnings;
use Digest::SHA qw(sha256_hex);
sub ans_fail { print STDERR "check-account-name-scope: $_[0]\n"; exit 2; }
sub ans_hash { return sha256_hex(lc $_[0]); }
sub ans_is_real_date {
	my ($s) = @_;
	return 0 unless defined $s && $s =~ /\A([0123456789]{4})-([0123456789]{2})-([0123456789]{2})\z/;
	my ($y, $m, $d) = ($1 + 0, $2 + 0, $3 + 0);
	return 0 if $m < 1 || $m > 12 || $d < 1;
	my @dim = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
	$dim[1] = 29 if ($y % 4 == 0 && $y % 100 != 0) || $y % 400 == 0;
	return $d <= $dim[$m - 1] ? 1 : 0;
}
# ans_load_rows(file) -> ([ {hash,role,glob,until,re}... ], {hash => role}); the file was made
# by this gate (header, rows, completion mark) and anything else is a refusal.
sub ans_load_rows {
	my ($file) = @_;
	open(my $in, '<', $file) or ans_fail("cannot read the normalised rows");
	my @lines = <$in>; close $in;
	ans_fail("the normalised rows are incomplete") unless @lines >= 2 && $lines[-1] eq "ANS_ROWS_OK\n" && $lines[0] eq "enabled\t1\n";
	my (@rows, %role_of);
	for my $i (1 .. $#lines - 1) {
		chomp(my $l = $lines[$i]);
		my ($h, $r, $g, $u) = split /\t/, $l, -1;
		my $re = join('[^/]*', map { quotemeta($_) } split(/\*/, $g, -1));
		push @rows, { hash => $h, role => $r, glob => $g, until => $u, re => qr/\A$re\z/ };
		$role_of{$h} = $r;
	}
	return (\@rows, \%role_of);
}
# The one counting rule (substring, case-blind, no word boundary): a name is found anywhere
# inside a run of [A-Za-z0-9_] — the run is lower-cased and every part of it of 3 to 12
# bytes (an XPR name is at most 12 long) is hashed and looked up. Content, paths and commit
# messages all go through ans_name_hashes; ans_redact uses the same cut. Both read
# ans_name_spans, which keeps only the longest match: a name lying wholly inside a longer
# name's place counts for the longer name's role only.
my %ANS_HASH_CACHE;
sub ans_cached_hash { my ($w) = @_; return exists $ANS_HASH_CACHE{$w} ? $ANS_HASH_CACHE{$w} : ($ANS_HASH_CACHE{$w} = ans_hash($w)); }
# ans_name_spans(text, role_of) -> ([start, length, hash]...) for every known name inside text
sub ans_name_spans {
	my ($t, $role_of) = @_;
	my @spans;
	while ($t =~ /([A-Za-z0-9_]{3,})/g) {
		my ($run, $base) = (lc $1, $-[1]);
		my $n = length $run;
		for my $len (3 .. ($n < 12 ? $n : 12)) {
			for my $i (0 .. $n - $len) {
				my $h = ans_cached_hash(substr($run, $i, $len));
				push @spans, [$base + $i, $len, $h] if exists $role_of->{$h};
			}
		}
	}
	# Longest match: a name whose place lies wholly inside the place of a longer name is
	# not counted (it counts for the longer name only). Names that stick out are kept.
	return grep { my $s = $_; !grep { $_->[1] > $s->[1] && $_->[0] <= $s->[0] && $_->[0] + $_->[1] >= $s->[0] + $s->[1] } @spans; } @spans;
}
# ans_name_hashes(text, role_of) -> the distinct hashes of the known names found inside text
sub ans_name_hashes { my ($t, $role_of) = @_; my %u; return grep { !$u{$_}++ } map { $_->[2] } ans_name_spans($t, $role_of); }
# ans_redact(text, role_of) -> the text with every known name replaced by <role> (again until none is left)
sub ans_redact {
	my ($t, $role_of) = @_;
	for (1 .. 20) {
		my @spans = sort { $a->[0] <=> $b->[0] || $b->[1] <=> $a->[1] } ans_name_spans($t, $role_of);
		last unless @spans;
		my ($out, $pos) = ('', 0);
		for my $s (@spans) {
			next if $s->[0] < $pos;
			$out .= substr($t, $pos, $s->[0] - $pos) . '<' . $role_of->{$s->[2]} . '>';
			$pos = $s->[0] + $s->[1];
		}
		$t = $out . substr($t, $pos);
	}
	return $t;
}
PERLEOF

# ---- perl: read and check the definition -> normalised rows -------------------------------
IFS= read -r -d '' ANS_PERL_ROWS <<'PERLEOF' || true
my ($cfg, $out, $today) = @ARGV;
my %ROLES = map { $_ => 1 } qw(anchor-account anchor-sink rehearsal-anchor-account rehearsal-anchor-sink);
open(my $in, '<', $cfg) or ans_fail("cannot read the scope definition");
binmode $in;
my ($enabled, $n, @rows, %seen, %role_of) = (undef, 0);
while (defined(my $line = <$in>)) {
	$n++; chomp $line;
	next if $line eq '' || substr($line, 0, 1) eq '#';
	my @f = split /\t/, $line, -1;
	if (!defined $enabled) {
		ans_fail("line $n: the first row must be enabled<TAB>1 or enabled<TAB>0")
			unless @f == 2 && $f[0] eq 'enabled' && ($f[1] eq '1' || $f[1] eq '0');
		$enabled = $f[1];
		last if $enabled eq '0';
		next;
	}
	ans_fail("line $n: a name row has exactly 5 tab-separated columns") unless @f == 5;
	my ($h, $r, $g, $u, $why) = @f;
	ans_fail("line $n: name_sha256 is not 64 lower-case hex characters") unless $h =~ /\A[0123456789abcdef]{64}\z/;
	ans_fail("line $n: role is not one of the four roles") unless $ROLES{$r};
	ans_fail("line $n: allowed_path_glob is empty or uses a sign other than *")
		if $g eq '' || substr($g, 0, 1) eq '/' || index($g, '..') >= 0 || index($g, '**') >= 0 || $g =~ /[\?\[\{\\]/;
	ans_fail("line $n: until is neither - nor a real YYYY-MM-DD date") unless $u eq '-' || ans_is_real_date($u);
	ans_fail("line $n: reason is empty") if $why eq '';
	ans_fail("line $n: the same row twice") if $seen{$line}++;
	ans_fail("line $n: one name hash under two roles") if exists $role_of{$h} && $role_of{$h} ne $r;
	$role_of{$h} = $r;
	push @rows, "$h\t$r\t$g\t$u\n";
}
ans_fail("enabled row missing") unless defined $enabled;
open(my $o, '>', $out) or ans_fail("cannot write the normalised rows");
if ($enabled eq '0') { print $o "enabled\t0\nANS_ROWS_OK\n"; close $o or ans_fail("write failed"); exit 0; }
ans_fail("FYD_NAME_SCOPE_TODAY or the system date is not a real YYYY-MM-DD date") unless ans_is_real_date($today);
ans_fail("the definition has no name rows") unless @rows;
print $o "enabled\t1\n", @rows, "ANS_ROWS_OK\n";
close $o or ans_fail("write failed");
PERLEOF

# ---- perl: scan the tracked tree (content and paths) -> hit lines ------------------------
IFS= read -r -d '' ANS_PERL_SCAN <<'PERLEOF' || true
use IPC::Open2;
my ($rows_file, $entries_file, $kind, $out_file) = @ARGV;
my (undef, $role_of) = ans_load_rows($rows_file);
open(my $ef, '<', $entries_file) or ans_fail("cannot read the entry list");
binmode $ef;
open(my $o, '>>', $out_file) or ans_fail("cannot write the hit list");
my $pid = open2(my $cf_out, my $cf_in, 'git', 'cat-file', '--batch');
binmode $cf_out; binmode $cf_in;
{ my $old = select($cf_in); $| = 1; select($old); }
my ($nfiles, %seen) = (0);
local $/ = "\0";
while (defined(my $rec = <$ef>)) {
	chomp $rec;
	my ($mode, $sha, $path);
	if ($kind eq 'tree') { ($mode, $sha, $path) = $rec =~ /\A([0123456789]+) \S+ ([0123456789abcdef]+)\t(.*)\z/s; }
	else                 { ($mode, $sha, $path) = $rec =~ /\A([0123456789]+) ([0123456789abcdef]+) [0123456789]\t(.*)\z/s; }
	ans_fail("an entry of the tree could not be read") unless defined $path;
	ans_fail("a tracked path holds a tab or a newline") if $path =~ /[\t\n]/;
	$nfiles++;
	for my $h (ans_name_hashes($path, $role_of)) {
		print $o "P\t$h\t$path\n" if !$seen{"P\t$h\t$path"}++;
	}
	next if $mode eq '160000';
	print $cf_in "$sha\n";
	my $hdr = do { local $/ = "\n"; <$cf_out> };
	ans_fail("git cat-file stopped answering") unless defined $hdr;
	$hdr =~ s/\n\z//;
	ans_fail("a tracked blob could not be read") unless $hdr =~ /\A[0123456789abcdef]+ \S+ ([0123456789]+)\z/;
	my ($size, $buf) = ($1, '');
	while (length($buf) < $size) {
		my $got = read($cf_out, $buf, $size - length($buf), length($buf));
		ans_fail("git cat-file output was cut") unless $got;
	}
	my $nl; read($cf_out, $nl, 1);
	my $lineno = 0;
	for my $line (split /\n/, $buf, -1) {
		$lineno++;
		for my $h (ans_name_hashes($line, $role_of)) {
			print $o "C\t$h\t$path\t$lineno\n" if !$seen{"C\t$h\t$path\t$lineno"}++;
		}
	}
}
close $cf_in; close $cf_out; waitpid($pid, 0);
ans_fail("git cat-file did not finish cleanly") if $? != 0;
print $o "ANS_SCAN_DONE\t$nfiles\n";
close $o or ans_fail("write failed");
PERLEOF

# ---- perl: scan commit messages -> hit lines -----------------------------------------------
IFS= read -r -d '' ANS_PERL_MSGS <<'PERLEOF' || true
my ($rows_file, $log_file, $out_file) = @ARGV;
my (undef, $role_of) = ans_load_rows($rows_file);
open(my $lf, '<', $log_file) or ans_fail("cannot read the commit log");
binmode $lf;
open(my $o, '>>', $out_file) or ans_fail("cannot write the hit list");
my %seen;
local $/ = "\0";
while (defined(my $rec = <$lf>)) {
	chomp $rec;
	my ($sha, $body) = $rec =~ /\A([0123456789abcdef]{40,64})\n(.*)\z/s;
	ans_fail("a commit record could not be read") unless defined $sha;
	for my $h (ans_name_hashes($body, $role_of)) {
		print $o "M\t$h\t" . substr($sha, 0, 12) . "\n" if !$seen{"$h\t$sha"}++;
	}
}
print $o "ANS_MSG_DONE\t1\n";
close $o or ans_fail("write failed");
PERLEOF

# ---- perl: judge -> VIOLATION / EXPIRED / OBSOLETE lines ------------------------------------
IFS= read -r -d '' ANS_PERL_JUDGE <<'PERLEOF' || true
my ($rows_file, $hits_file, $today) = @ARGV;
my ($rows, $role_of) = ans_load_rows($rows_file);
open(my $hf, '<', $hits_file) or ans_fail("cannot read the hit list");
my (@content, @paths, @msgs, $nfiles);
while (defined(my $l = <$hf>)) {
	chomp $l;
	my @f = split /\t/, $l, -1;
	if    ($f[0] eq 'C' && @f == 4) { push @content, [@f[1 .. 3]]; }
	elsif ($f[0] eq 'P' && @f == 3) { push @paths,   [@f[1 .. 2]]; }
	elsif ($f[0] eq 'M' && @f == 3) { push @msgs,    [@f[1 .. 2]]; }
	elsif ($f[0] eq 'ANS_SCAN_DONE' && @f == 2) { $nfiles = $f[1]; }
	elsif ($f[0] eq 'ANS_MSG_DONE') { }
	else { ans_fail("an unknown line in the hit list"); }
}
ans_fail("the scan did not report a file count") unless defined $nfiles;
my (@violation, @expired, @obsolete);
my @active = grep { $_->{until} eq '-' || $_->{until} ge $today } @$rows;
for my $r (grep { $_->{until} ne '-' && $_->{until} lt $today } @$rows) {
	push @expired, "EXPIRED $r->{role} " . ans_redact($r->{glob}, $role_of) . " $r->{until}";
}
for my $c (@content) {
	my ($h, $path, $line) = @$c;
	next if grep { $_->{hash} eq $h && $path =~ $_->{re} } @active;
	push @violation, "VIOLATION " . ans_redact($path, $role_of) . ":$line $role_of->{$h}";
}
push @violation, map { "VIOLATION " . ans_redact($_->[1], $role_of) . ":path $role_of->{$_->[0]}" } @paths;
push @violation, map { "VIOLATION commit:$_->[1] $role_of->{$_->[0]}" } @msgs;
for my $r (@active) {
	next if grep { $_->[0] eq $r->{hash} && $_->[1] =~ $r->{re} } @content;
	push @obsolete, "OBSOLETE $r->{role} " . ans_redact($r->{glob}, $role_of);
}
my %u;
for my $set (\@violation, \@expired, \@obsolete) { @$set = sort grep { !$u{$_}++ } @$set; print "$_\n" for @$set; }
print "ANS_JUDGE_DONE\t$nfiles\n";
PERLEOF

# ans_run_perl <program> <args...>: run COMMON + program under perl; the caller reads the mark.
ans_run_perl() {
	local prog="$1"; shift
	perl -e "${ANS_PERL_COMMON}${prog}" -- "$@"
}

# ans_last_line_is <file> <mark>: the file's last line starts with the completion mark.
ans_last_line_is() { [ -f "$1" ] && [ "$(tail -n 1 "$1" | cut -f1)" = "$2" ]; }

# ans_read_scope_rows <definition> <out> <today>: check the definition, write normalised rows.
ans_read_scope_rows() {
	ans_run_perl "$ANS_PERL_ROWS" "$1" "$2" "$3" || ans_die "the scope definition was refused"
	ans_last_line_is "$2" "ANS_ROWS_OK" || ans_die "the scope definition was not fully read"
}

# ans_list_entries <kind> <out>: the tracked entries of HEAD (tree) or of the index (index).
ans_list_entries() {
	if [ "$1" = "index" ]; then
		git ls-files -s -z > "$2" 2>"$TMP/git.err" || ans_die "git ls-files failed"
	else
		git ls-tree -r -z --full-tree HEAD > "$2" 2>"$TMP/git.err" || ans_die "git ls-tree failed"
	fi
}

# ans_scan_tracked_files <kind>: append C/P hit lines and the file-count mark to $TMP/hits.
ans_scan_tracked_files() {
	ans_list_entries "$1" "$TMP/entries"
	ans_run_perl "$ANS_PERL_SCAN" "$TMP/rows" "$TMP/entries" "$1" "$TMP/hits" || true
	ans_last_line_is "$TMP/hits" "ANS_SCAN_DONE" || ans_die "the scan of the tracked files did not complete"
}

# ans_scan_commit_messages <base>: append M hit lines and the mark to $TMP/hits.
ans_scan_commit_messages() {
	git rev-parse --verify -q "$1^{commit}" >/dev/null 2>&1 || ans_die "the base of --messages is not a commit"
	git log -z --format='%H%n%B' "$1..HEAD" > "$TMP/log" 2>"$TMP/git.err" || ans_die "git log failed"
	ans_run_perl "$ANS_PERL_MSGS" "$TMP/rows" "$TMP/log" "$TMP/hits" || true
	ans_last_line_is "$TMP/hits" "ANS_MSG_DONE" || ans_die "the scan of the commit messages did not complete"
}

# ans_judge <today>: print the verdict lines; the last line of $TMP/verdict is the mark.
ans_judge() {
	ans_run_perl "$ANS_PERL_JUDGE" "$TMP/rows" "$TMP/hits" "$1" > "$TMP/verdict" || true
	ans_last_line_is "$TMP/verdict" "ANS_JUDGE_DONE" || ans_die "the judgement did not complete"
}

ans_main() {
	local kind="tree" base="" use_index=0 use_messages=0 a
	for a in "$@"; do
		case "$a" in
			--index) use_index=1 ;;
			--messages=*) base="${a#--messages=}"; [ -n "$base" ] || ans_die "--messages needs a base"; use_messages=1 ;;
			-h|--help) ans_usage; exit 0 ;;
			*) ans_die "unknown argument (see --help)" ;;
		esac
	done
	[ "$use_index" -eq 0 ] || [ "$use_messages" -eq 0 ] || ans_die "--index and --messages cannot be combined"
	[ "$use_index" -eq 0 ] || kind="index"

	command -v perl >/dev/null 2>&1 || ans_die "perl is not on PATH"
	perl -MDigest::SHA -e 'exit 0' >/dev/null 2>&1 || ans_die "perl cannot load Digest::SHA"
	local top config today
	top="$(git rev-parse --show-toplevel 2>/dev/null)" || ans_die "not inside a git repository"
	config="${FYD_NAME_SCOPE_CONFIG-$top/$ANS_CONFIG}"
	if [ "${FYD_NAME_SCOPE_TODAY+set}" = "set" ]; then today="$FYD_NAME_SCOPE_TODAY"; else today="$(date -u +%Y-%m-%d)" || ans_die "date failed"; fi

	TMP="$(mktemp -d)" || ans_die "mktemp failed"
	trap 'rm -rf "$TMP"' EXIT
	ans_read_scope_rows "$config" "$TMP/rows" "$today"
	if [ "$(head -n 1 "$TMP/rows")" = "$(printf 'enabled\t0')" ]; then echo "DISABLED"; exit 0; fi

	cd "$top" || ans_die "cannot enter the repository root"
	git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1 || ans_die "HEAD is not a commit"
	: > "$TMP/hits"
	ans_scan_tracked_files "$kind"
	[ "$use_messages" -eq 0 ] || ans_scan_commit_messages "$base"
	ans_judge "$today"

	local mark nlines
	mark="$(tail -n 1 "$TMP/verdict")"
	nlines="$(wc -l < "$TMP/verdict" | tr -d ' ')"
	if [ "$nlines" -gt 1 ]; then sed '$d' "$TMP/verdict"; exit 1; fi
	echo "OK ${mark#*	} files"
	exit 0
}

ans_main "$@"
