# All rights reserved. This program is free software; you can redistribute
# it and/or modify it under the same terms as Perl itself.

package CGI::Compress::Transparent;

use strict;
use warnings;
use IO::Compress::Gzip qw(gzip $GzipError :flush) ;
#use Tie::Handle;
use Symbol;
use vars qw($VERSION $AUTOLOAD @ISA);

#use Data::Dumper;

sub import {
    #nothing
}

#@ISA = qw(Tie::Handle);

our $ext_fh;

our $gzip_handle;

our $header_is_done;
our $header_text;
our $header_length_already_printed;
our $using_compression;

sub TIEHANDLE
{
    my $class = shift;
    my @args = @_;

    my $self = bless {}, $class;

    return @args ? $self->OPEN(@args) : $self;
}

sub print_plain{
    #no strict 'refs';
    print $ext_fh @_;
}

sub print_gzip{
    #warn "zip print @_\n";
    $gzip_handle->print(@_) or die "cant print to gzip handle";
    $gzip_handle->flush(Z_SYNC_FLUSH) or die "can't flush gzip handle";
}

sub PRINT {
    my $self = shift;

    #my @args = map {uc} @_;
    my @args = @_;

    my $text_deferred_till_next_iteration;

    ARG: for(my $i=0;$i<=$#args;$i++){

        my $arg = $args[$i];



        unless($header_is_done){

            if(length($arg)>1000){
                #my $len_b4 = length $arg;
                my $arg_right = substr($arg, 1000);
                $arg = substr($arg, 0, 1000);
                #my $len_after = length($arg_right)+length($arg);

                #warn "before $len_b4, after $len_after" if $len_b4 != $len_after;

                $args[$i] = $arg;
                #my $size_b4 = $#args;
                splice(@args, $i+1, 0, $arg_right);
                #my $size_after = $#args;

                #warn "size before $size_b4, size after $size_after" if $size_after != $size_b4+1;


            }

            $header_text .= $arg;

            if(length($header_text) > 10000){
                #warn "havent seen a header in the first 10k chars printed, should definitely just give up\n";
                #warn "not using compression";
                print_plain($arg);
                $header_is_done=1;
                next ARG;
            }
            if($i > 30){
                #warn "havent seen a header in the first 30 print statements??? Oh my...\n";
                #warn "not using compression";
                print_plain($arg);
                $header_is_done=1;
                next ARG;
            }

            my $cr = "\cM";
            my $lf = "\cJ";
            my $crlf = "$cr$lf";

            my $match_n = "$cr?$lf";

            #my $n = "\cM\cJ";
            #my $header_end_index = index($header_text, "$n$n");
            #if($header_end_index!=-1){
                #$header_end_index-=0;
            if($header_text =~ /$match_n$match_n/){
                my $after_pos = $+[0];
                my $double_newline_length = $+[0] - $-[0];
                my $header_end_index = $after_pos - $double_newline_length;
                #warn "double newline found at $header_end_index\n";
                #warn "len before chopping: ".length($header_text);
                my $after_header_text=substr($header_text, $header_end_index);
                my $header_text = substr($header_text, 0, $header_end_index);
                $header_is_done=1;

                #warn Dumper $header_text;
                my @headers_seen = split /$match_n/, "$header_text";
                #warn "SAW HEADERS:".Dumper \@headers_seen;
                my $saw_ok_content_type = 0;
                my $saw_something_uncompressible = 0;
                HEADER: for my $header(@headers_seen){
                    if($header =~ /^Content-Type:\s+text\//i){
                        #warn "good content type\n";
                        $saw_ok_content_type = 1;
                    }
                    elsif($header =~ /^Status:\s+(\d+)/i){
                        if($1 != 200){
                            $saw_something_uncompressible=1;
                            last HEADER;
                        }
                    }
                    elsif($header =~ /^Content-Encoding:/i){
                        $saw_something_uncompressible=1;
                        last HEADER;
                    }
                }
                if($saw_something_uncompressible  or not $saw_ok_content_type){
                    #warn "not using compression";
                    print_plain($arg);
                    next ARG;
                }else{
                    #warn "using compression";
                    $using_compression=1;
                }



                #warn "AFTER HEADER TEXT: ".Dumper $after_header_text;

                my $header_text_not_printed = ($header_length_already_printed<length($header_text)?substr($header_text, $header_length_already_printed):'');
                #warn "HEADER NOT YET PRINTED: ".Dumper($header_text_not_printed);
                print_plain($header_text_not_printed);
                print_plain($crlf."Content-Encoding: gzip$crlf$crlf");
                $gzip_handle = new IO::Compress::Gzip $ext_fh or die "cant create Gzip fh";
                print_gzip(substr($after_header_text,$double_newline_length)) if length($after_header_text)>$double_newline_length;
                next ARG;
                #warn "len after chopping: ".length($header_text.$after_header_text);
            }
        }

        unless($header_is_done){
            $header_length_already_printed += length($arg);
            print_plain($arg);
        }else{
            if($using_compression){
                print_gzip($arg);
            }else{
                print_plain($arg);
            }
        }



    }

    if($header_is_done and not $using_compression){
        #warn "undoing the select...";
        select \*STDOUT;
    }

}

sub new
{
    my $class = shift;
    my @args = @_;

    my $self = gensym();

    tie *{$self}, $class, @args;

    return tied(${$self}) ? bless $self, $class : undef;
}

sub isCompressibleType{
   my $type = shift;

   return ($type || q{}) =~ m/ \A text\/ /xms;
}

sub userAcceptsGzip{
   my $acc = $ENV{HTTP_ACCEPT_ENCODING};
   if (!$acc || $acc !~ m/ \bgzip\b /ixms){
        return 0;
   }else{
        return 1;
   }
}

sub init{
    #warn "user dont accept gzip" unless userAcceptsGzip;
    return unless userAcceptsGzip;

    $header_is_done=0;
    $header_text='';
    $header_length_already_printed=0;
    $using_compression=0;

    $ext_fh = \*STDOUT;
    my $tied_fh = new __PACKAGE__ or die "can't create tied fh";

    select $tied_fh or die "cant select tied fh";
}


1;