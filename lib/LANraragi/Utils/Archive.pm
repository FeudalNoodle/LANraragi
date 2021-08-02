package LANraragi::Utils::Archive;

use strict;
use warnings;
use utf8;

use Time::HiRes qw(gettimeofday);
use File::Basename;
use File::Path qw(remove_tree make_path);
use File::Find qw(finddepth);
use File::Copy qw(move);
use Encode;
use Encode::Guess qw/euc-jp shiftjis 7bit-jis/;
use Redis;
use Cwd;
use Image::Magick;
use Archive::Libarchive::Extract;
use Archive::Libarchive::Peek;

use LANraragi::Utils::TempFolder qw(get_temp);
use LANraragi::Utils::Logging qw(get_logger);
use LANraragi::Utils::Generic qw(is_image shasum);

# Utilitary functions for handling Archives.
# Relies on Libarchive, ImageMagick and GhostScript for PDFs.
use Exporter 'import';
our @EXPORT_OK = qw(is_file_in_archive extract_single_file extract_file_from_archive get_filelist extract_archive extract_thumbnail generate_thumbnail);

sub is_pdf {
    my ( $filename, $dirs, $suffix ) = fileparse( $_[0], qr/\.[^.]*/ );
    return ( $suffix eq ".pdf" );
}

# generate_thumbnail(original_image, thumbnail_location)
# use ImageMagick to make a thumbnail, height = 500px (view in index is 280px tall)
sub generate_thumbnail {

    my ( $orig_path, $thumb_path ) = @_;
    my $img = Image::Magick->new;

    $img->Read($orig_path);
    $img->Thumbnail( geometry => '500x1000' );
    $img->Set( quality => "50", magick => "jpg" );
    $img->Write($thumb_path);
    undef $img;
}

# sanitize_filename(filename)
# Converts filenames to an ascii variant to avoid extra filesystem headaches.
sub sanitize_filename {

    my $filename = $_[0];
    eval {
        # Try a guess to regular japanese encodings first
        $filename = decode( "Guess", $filename );
    };

    # Fallback to utf8
    $filename = decode_utf8($filename) if $@;

    # Re-encode the result to ASCII and move the file to said result name.
    # Use Encode's coderef feature to map non-ascii characters to their Unicode codepoint equivalent.
    $filename = encode( "ascii", $filename, sub { sprintf "%04X", shift } );

    if ( length $filename > 254 ) {
        $filename = substr( $filename, 0, 254 );
    }

    return $filename;
}

# extract_archive(path, archive_to_extract, force)
# Extract the given archive to the given path.
# This sub won't re-extract files already present in the destination unless force = 1.
sub extract_archive {

    my ( $destination, $to_extract, $force_extract ) = @_;

    # PDFs are handled by Ghostscript (alas)
    if ( is_pdf($to_extract) ) {
        return extract_pdf( $destination, $to_extract );
    }

    # Prepare libarchive with a callback to skip over existing files (unless force=1)
    my $ae = Archive::Libarchive::Extract->new( filename => $to_extract, 
        entry => sub ($e) {

            if ($force_extract) { return 1; }

            my $filename = $e->pathname;
            $filename = sanitize_filename($filename);
            return -e "$destination/$filename";
    });

    # Extract to $destination. This method throws if extraction fails.
    $ae->extract( to => $destination );

    # Get extraction folder
    $result_dir = $ae->to;

    #Rename files and folders to an encoded version
    my $cwd = getcwd();

    finddepth(
        sub {
            unless ( $_ eq '.' ) {
                move( $_, sanitize_filename($_) );
            }
        },
        $result_dir
    );

    # chdir back to the base cwd in case finddepth died midway
    chdir $cwd;

    # Return the directory we extracted the files to.
    return $result_dir;
}

sub extract_pdf {
    my ( $destination, $to_extract ) = @_;

    make_path($destination);
    my $logger = get_logger( "Archive", "lanraragi" );

    my $gscmd = "gs -dNOPAUSE -sDEVICE=jpeg -r200 -o '$destination/\%d.jpg' '$to_extract'";
    $logger->debug("Sending PDF $to_extract to GhostScript...");
    $logger->debug($gscmd);

    `$gscmd`;

    return $destination;
}

# extract_thumbnail(thumbnaildir, id)
# Finds the first image for the specified archive ID and makes it the thumbnail.
sub extract_thumbnail {

    my ( $thumbdir, $id ) = @_;

    # Another subfolder with the first two characters of the id is used for FS optimization.
    my $subfolder = substr( $id, 0, 2 );
    my $thumbname = "$thumbdir/$subfolder/$id.jpg";

    make_path("$thumbdir/$subfolder");
    my $redis = LANraragi::Model::Config->get_redis;

    my $file     = $redis->hget( $id, "file" );
    my $temppath = get_temp . "/thumb/$id/";

    # Make sure the thumb temp dir exists
    make_path($temppath);

    my $arcimg = "";
    if ( is_pdf($file) ) {
        $arcimg = extract_cover_pdf( $file, $temppath );
    } else {
        $arcimg = extract_cover_libarchive( $file, $temppath );
    }

    # While we have the image, grab its SHA-1 hash for tag research.
    # That way, no need to repeat the costly extraction later.
    my $shasum = shasum( $arcimg, 1 );
    $redis->hset( $id, "thumbhash", $shasum );
    $redis->quit();

    #Thumbnail generation
    generate_thumbnail( $arcimg, $thumbname );

    #Delete the previously extracted file.
    unlink $arcimg;

    # Clean up safe folder
    remove_tree($temppath);
    return $thumbname;
}

sub extract_cover_pdf {

    my ( $file, $temppath ) = @_;
    mkdir $temppath;
    my $output = $temppath . "pdf_first_page.jpg";

    my $logger = get_logger( "Archive", "lanraragi" );

    my $gscmd = "gs -dNOPAUSE -dLastPage=1 -sDEVICE=jpeg -r72 -o '$output' '$file'";
    $logger->debug("Sending PDF $file to GhostScript...");
    $logger->debug($gscmd);

    `$gscmd`;

    return $output;
}

sub extract_cover_libarchive {

    my ( $file, $temppath ) = @_;

    # Get all the files of the archive
    my $peek  = Archive::Libarchive::Peek->new( filename => $file );
    my @files = $peek->files;
    my @extracted;

    # Filter out non-images
    foreach my $file (@files) {
        if ( is_image($file) ) {
            push @extracted, $file;
        }
    }

    @extracted = sort { lc($a) cmp lc($b) } @extracted;

    # Get the first file of the list and spit it out into a file
    my $contents = $peek->file( $extracted[0] );

    # The name sometimes comes with the folder as a bonus, so we use basename to filter it out.
    my ( $filename, $dirs, $suffix ) = fileparse( $extracted[0], qr/\.[^.]*/ );

    # Move the extracted file to a safe folder to avoid concurrent overwrites
    my $arcimg = $temppath . $filename . $suffix;

    open( my $fh, '>', $arcimg )
      or die "Could not open file '$arcimg' $!";
    print $fh $contents;
    close $fh;

    return $arcimg;
}

# get_filelist($archive)
# Returns a list of all the files contained in the given archive.
sub get_filelist {

    my $archive = $_[0];
    my @files = ();

    if ( is_pdf($archive) ) {
        # For pdfs, extraction returns images from 1.jpg to x.jpg, where x is the pdf pagecount.
        my $pages = `gs -q -c "($archive) (r) file runpdfbegin pdfpagecount = quit"`;
        for my $num (1 .. $pages) {
            push @files, "$num.jpg";
        }
    } else {
        my $peek = Archive::Libarchive::Peek->new( filename => $archive );
        # Filter out non-images
        foreach my $file ($peek->files) {
            if ( is_image($file) ) {
                push @files, $file;
            }
        }
    }

    return @files;
}

# is_file_in_archive($archive, $file)
# Uses Libarchive::Peek to figure out if $archive contains $file.
# Returns 1 if it does exist, 0 otherwise.
sub is_file_in_archive {

    my ( $archive, $wantedname ) = @_;

    my $logger = get_logger( "Archive", "lanraragi" );

    if ( is_pdf($archive) ) {
        $logger->debug("$archive is a pdf, no sense looking for specific files");
        return 0;
    }

    $logger->debug("Iterating files of archive $archive, looking for '$wantedname'");

    my $peek  = Archive::Libarchive::Peek->new( filename => $archive );
    my $found = 0;
    $peek->iterate(
        sub {
            my $name = $_[0];
            $logger->debug( "Found file $name" );

            if ( $name =~ /$wantedname$/ ) {
                $found = 1;
            }
        }
    );

    return $found;
}

# extract_single_file ($archive, $file, $destination)
# Extract $file from $archive to $destination and returns the filesystem path it's extracted to.
# If the file doesn't exist in the archive, this will still create a file, but empty.
sub extract_single_file {

    my ($archive, $filename, $destination) = @_;

    my $contents = "";
    unless ( is_pdf($archive) ) {
        my $peek = Archive::Peek::Libarchive->new( filename => $archive );
        $peek->iterate(
            sub {
                my ( $file, $data ) = @_;

                if ( $file =~ /$filename$/ ) {
                    $contents = $data;
                }
            }
        );
    }

    my $outfile = "$destination/$filename";

    open( my $fh, '>', $outfile )
      or die "Could not open file '$outfile' $!";
    print $fh $contents;
    close $fh;

    return $outfile;
}

# extract_file_from_archive($archive, $file)
# Variant for plugins. 
# Extracts the file with a timestamp to a folder in /temp/plugin.
sub extract_file_from_archive {

    my ( $archive, $filename ) = @_;

    # Timestamp extractions in microseconds
    my ( $seconds, $microseconds ) = gettimeofday;
    my $stamp = "$seconds-$microseconds";
    my $path  = get_temp . "/plugin/$stamp";
    mkdir get_temp . "/plugin";
    mkdir $path;
    
    return extract_single_file($archive, $filename, $path);
}

1;
