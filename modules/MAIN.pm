#!/usr/bin/perl

package MAIN;

use strict;
use warnings;

use Email::Send;
use Email::MIME::Creator;
use IO::All;
use Digest::MD5 qw( md5_hex );
use File::Path qw( make_path remove_tree );
use POSIX qw( strftime );
use Time::HiRes qw( gettimeofday tv_interval );

use CONFIG;
use MAIN::Cache;
use MAIN::Laconic;

our $VERSION = '0.1';
our @ISA     = qw( Exporter );
our @EXPORT  = qw(
                $CONFIG $CONFIG_TEMPLATE $CONFIG_IMAGES
                redirect redirect2 back
                access 
                module
                to_log
                thumbnail_images resize
                email
                make_path remove_tree
                ban forbid
            );
our @EXPORT_OK  = qw(
                gettimeofday tv_interval
                md5_hex
            );
our %EXPORT_TAGS = (
                all   => [ @EXPORT, @EXPORT_OK ],
                time  => [ qw( gettimeofday tv_interval ) ],
                file  => [ qw( make_path remove_tree ) ],
            );

## get all access rules
sub access {
    $_ = eval { local $SIG{__DIE__}; do $CONFIG->{config_files_path}.'/access.pl' };
    $_->{$main::SESSION->param('sgroup')};
}

=head1 module
 get result from subsections $module with $link section and @arg arguments
 if there is no modules, system gets module, regards to path of link
 for example:
    $body = module( '&begin', "/DEFAULT.hash", 'abc', 123 );
        system will get module DEFAULT.hash in modules path, 
        then execute &begin subsection with ('abc', 123) parameters
    $body = module('/admin/news/edit/123');
        System will try to find /admin/news/edit/123.hash link, then /admin/news/edit.hash, 
        then /admin/news.hash and stop search, 'cause found last one.
        After that, system will find '/admin/news/edit/(\d+)' section in
        /admin/news.hash module by regexp with $link.
        Then, system execute this section with '123' argument.
=cut
sub module {
    my ( $link, $module, @arg ) = @_;
    my ( %main, @modules );
    if ( $module ) {
        $module = $CONFIG->{modules_path}.'/'.$module;
    } else {
        push @modules, $1 while ( $link =~ m%/([\w\d]+[\w\d\.]*)%g );
        while ( @modules ) {
            $module = $CONFIG->{modules_path}."/".(join '/', @modules).".".$CONFIG->{modules_extension};
            last if -f $module;
            undef $module;
            pop @modules;
        }
        $module = $CONFIG->{modules_path}."/DEFAULT.hash" unless $module;
        $module = $CONFIG->{modules_path}."/.hash" unless $link;
    }
    if (-f $module) {
        my $ref = eval { local $SIG{__DIE__}; do $module; };
        return to_log( $@ ) if $@;
        return to_log( `cd $CONFIG->{modules_path} && perl -c $module 2>&1` ) unless $ref;
        return $ref unless ref($ref);
        if (ref($ref) eq 'HASH') { %main = (%main, %$ref); };
    }
    foreach (sort {length $b <=> length $a} keys %main) {
        if (my @arr = $link =~ /^$_$/) {
            return $main{$_}( @arg, @arr );
        }
    }
    return '';
}

sub to_log {
    my ( $filename, @data ) = ( ref($_[0]) ne 'HASH' )? ( $CONFIG->{log_error}, @_ ):( $_[0]->{filename}, @{$_[0]->{data}} );
    open F, '>>', $filename;
    foreach ( @data ) {
        print F $ENV{REMOTE_ADDR};
        print F (strftime " [%F %T] - ", localtime);
        s/\r|\n//g;
        print F $_."\n";
    }
    close F;
}

## 302 redirect
sub redirect {
    $_ = shift || '';
    my $url = shift || $main::q->server_name;
    my $lang = shift || '';
    my $rtype = shift || "302 Found\nCache-Control: no-cache, must-revalidate\nExpires: Sat, 26 Jul 1997 05:00:00 GMT";
    $url = $lang.'.'.$url if $lang && $lang ne $CONFIG->{default_language};
    $main::header = "HTTP/1.1 $rtype";
    my $protocol = ($main::q->https)? 'https' : 'http';
    my $port = ($main::q->virtual_port != 80)? ':'.$main::q->virtual_port : '';
    print "location: $protocol://$url$port/$_\n\n";
}

## Javascript redirect
sub redirect2 {
    $_ = shift || '';
    my $url = shift || 'http://'.$CONFIG->{site};
    $url .= '/'.$_;
    return '<script type="text/javascript">window.location = "'.$url.'"</script>';
}

## redirect to HTTP_REFERER page
sub back {
    redirect( $1 ) if $ENV{'HTTP_REFERER'} =~ m%https?://.*?/(.*)%;
}

## resize image
sub resize {
    use Image::Magick;
    my ( $from, $to, $width, $height ) = @_;
    return 0 unless ($from && -e $from);
    my $img = Image::Magick->new;
    $img->Read($from);
    my ($w,$h) = $img->Get('width','height');
    my $new_height = $height;
    my $new_width = int($w * ($height / $h));
    if( ( $new_width < $width && $width < 200 ) || ( $new_width > $width && $width > 200 ) ) {
        $new_width = $width;
        $new_height = int($h * ($width / $w));
    }
    $img->Resize(width=>$new_width, height=>$new_height);
    if( $width<200 ) {
        $img->Crop( x=>(($new_width>$width)?int(($new_width-$width)/2):0), 
#            y=>(($new_height>$height)?int(($new_height-$height)/2):0), 
# vertical photo crop to top
            y=>0, 
            width=>$width, height=>$height);
    }
    $img->Sharpen();
=c
    $img->Normalize();
    $img->AutoLevel();
    $img->AutoGamma();
=cut
    $img->Write($to);
}

sub thumbnail_images {
    my @id = @_;
    my $CONFIG_IMAGES = $main::CONFIG_IMAGES;
    my $tmp = $CONFIG_IMAGES->{PATH}.'tmp.jpg';
    unless (@id) {
        my $r = $main::db->sql ( "SELECT ship_id FROM documents WHERE doc_type='jpg' group by ship_id" );
        return 0 unless( @$r );
        @id = map { $_->{ship_id} } @$r;
    }
    foreach (@id) {
        my $r = $main::db->sql ( "SELECT * FROM documents WHERE doc_type='jpg' AND ship_id=?", $_ );
        foreach my $img (@$r) {
            open F, '>', $tmp;
            binmode F;
            print F $img->{doc_content};
            close F;
            foreach my $size ( @{$CONFIG_IMAGES->{SIZE}} ) {
                my $path = $CONFIG_IMAGES->{PATH}.$size.'/';
                mkdir $path unless -d $path;
                resize ( $tmp, $path.$img->{ship_id}.'-'.$img->{doc_id}.'.jpg', split( 'x', $size ) );
            }
            unlink $tmp;
        }
    }

    return 1;
}

sub email {

    my $_ = shift;
    my $from = $_->{From} || $CONFIG->{email};
    my $to = $_->{To} || $CONFIG->{email};
    my $subject = $_->{Subject} || 'Message from website';
    my $email = Email::MIME->create(
        header => [
            From    => $from,
            To      => $to,
            Subject => $subject,
        ],
        body => $_->{Message} || 'This is a test message',
    );

    $email->header_set( 'Content-type' => 'text/plain; charset="utf-8"' );

if( keys %{$_->{Image}} ) {

    my @parts = (
      Email::MIME->create(
          attributes => {
              charset      => "UTF-8",
          },
              body => '',
      )
    );

    foreach my $img_name ( keys %{$_->{Image}} ) {
        next unless $img_name =~ /(jpg|jpeg|png|pdf|doc|docx|rtf|xls|tar|gz|txt)$/i;
        my $img = $_->{Image}->{$img_name};
        push @parts, 
        Email::MIME->create(
                attributes => {
                filename     => $img_name,
                content_type => "application/download",
                encoding     => "base64",
#                disposition  => 'attachment',
#                content_type => "image/jpeg",
#                encoding     => "quoted-printable",
                name         => $img,
            },
            body => io( $img )->all,
        );
    }

    $email->parts_set(
        [
                $email->parts,
            Email::MIME->create( parts => [ @parts ] ),
        ],
    );
}

    my $bulk = Email::Send->new;
    for ( qw[Sendmail SMTP Qmail] ) {
        $bulk->mailer($_) and last if $bulk->mailer_available($_);
    }
    my $rv = $bulk->send($email);

}

=head1 MAIN

=head1 SYNOPSIS

=head1 DESCRIPTION

[enter your description here]

=head1 SEE ALSO

L<Email::Send>, L<Email::MIME::Creator>, L<Image::Magick>

=head1 AUTHOR

ivanoff, http://ivanoff.org.ua, 2@ivanoff.org.ua,

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
