#!/usr/bin/env perl
# md2html.pl — minimal markdown -> HTML body converter for planpage.
# Reads markdown on stdin, writes body HTML on stdout.
# Supported subset: #-###### headings, ``` fences, paragraphs, ul/ol lists
# (single level), > blockquotes, | tables |, ---, `code`, **bold**, *italic*,
# [links](url), ![images](url).
use strict;
use warnings;

my @out;
my $para    = '';
my $list    = '';    # '', 'ul', 'ol'
my $in_code = 0;
my @bq;
my @table;

sub esc {
    my $s = shift;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

sub inline {
    my $s = esc(shift);
    my @codes;
    # protect code spans from the other inline transforms
    $s =~ s/`([^`]+)`/push @codes, $1; "\x01$#codes\x01"/ge;
    $s =~ s/!\[([^\]]*)\]\(([^)\s]+)\)/<img alt="$1" src="$2" style="max-width:100%">/g;
    $s =~ s/\[([^\]]+)\]\(([^)\s]+)\)/<a href="$2">$1<\/a>/g;
    $s =~ s/\*\*([^*]+)\*\*/<strong>$1<\/strong>/g;
    $s =~ s/(?<![*\w])\*([^*]+)\*(?![*\w])/<em>$1<\/em>/g;
    $s =~ s/\x01(\d+)\x01/'<code>' . $codes[$1] . '<\/code>'/ge;
    return $s;
}

sub flush_para {
    if ( $para ne '' ) {
        push @out, '<p>' . inline($para) . '</p>';
        $para = '';
    }
}

sub flush_list {
    if ($list) { push @out, "</$list>"; $list = ''; }
}

sub flush_bq {
    if (@bq) {
        push @out, '<blockquote><p>' . inline( join ' ', @bq ) . '</p></blockquote>';
        @bq = ();
    }
}

sub split_row {
    my $r = shift;
    $r =~ s/^\s*\|//;
    $r =~ s/\|\s*$//;
    return map { my $c = $_; $c =~ s/^\s+|\s+$//g; $c } split /\|/, $r, -1;
}

sub flush_table {
    return unless @table;
    my @rows = @table;
    @table = ();
    my $html = '<table>';
    my $has_header = @rows >= 2 && $rows[1] =~ /^\s*\|[\s:\-|]+\|\s*$/;
    if ($has_header) {
        $html .= '<thead><tr>'
          . join( '', map { '<th>' . inline($_) . '</th>' } split_row( $rows[0] ) )
          . '</tr></thead>';
        splice @rows, 0, 2;
    }
    $html .= '<tbody>';
    for my $r (@rows) {
        next if $r =~ /^\s*\|[\s:\-|]+\|\s*$/;
        $html .= '<tr>'
          . join( '', map { '<td>' . inline($_) . '</td>' } split_row($r) )
          . '</tr>';
    }
    $html .= '</tbody></table>';
    push @out, $html;
}

sub flush_all { flush_para(); flush_list(); flush_bq(); flush_table(); }

while ( my $line = <STDIN> ) {
    chomp $line;
    $line =~ s/\r$//;

    if ( $line =~ /^```/ ) {
        flush_all();
        push @out, $in_code ? '</code></pre>' : '<pre><code>';
        $in_code = !$in_code;
        next;
    }
    if ($in_code) { push @out, esc($line); next; }

    if ( $line =~ /^\s*\|.*\|\s*$/ ) { flush_para(); flush_list(); flush_bq(); push @table, $line; next; }
    flush_table();

    if ( $line =~ /^(#{1,6})\s+(.*)$/ ) {
        flush_all();
        my $l = length $1;
        push @out, "<h$l>" . inline($2) . "</h$l>";
        next;
    }
    if ( $line =~ /^(?:---+|\*\*\*+|___+)\s*$/ ) { flush_all(); push @out, '<hr>'; next; }
    if ( $line =~ /^>\s?(.*)$/ ) { flush_para(); flush_list(); push @bq, $1; next; }
    flush_bq();

    if ( $line =~ /^\s*[-*+]\s+(.*)$/ ) {
        flush_para();
        my $item = $1;
        if ( $list ne 'ul' ) { flush_list(); push @out, '<ul>'; $list = 'ul'; }
        push @out, '<li>' . inline($item) . '</li>';
        next;
    }
    if ( $line =~ /^\s*\d+[.)]\s+(.*)$/ ) {
        flush_para();
        my $item = $1;
        if ( $list ne 'ol' ) { flush_list(); push @out, '<ol>'; $list = 'ol'; }
        push @out, '<li>' . inline($item) . '</li>';
        next;
    }

    if ( $line =~ /^\s*$/ ) { flush_all(); next; }

    flush_list();
    $para = $para eq '' ? $line : "$para $line";
}

push @out, '</code></pre>' if $in_code;
flush_all();

print join( "\n", @out ), "\n";
