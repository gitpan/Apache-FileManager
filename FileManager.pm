package Apache::FileManager;


=head1 NAME

Apache::FileManager - Apache file manager

=head1 SYNOPSIS

Install in mod_perl enabled apache conf file
     <Location /FileManager>
       SetHandler           perl-script
       PerlHandler          Apache::FileManager
     </Location>

Or call from your own mod_perl script
  use Apache::FileManager;

  #before the header has been sent
  my $obj = Apache::FileManager->new();

  #after header has been sent
  $obj->print();

=head1 DESCRIPTION

The Apache::FileManager module is a simple HTML file manager. It provides file manipulations such as cut, copy, paste, delete, rename, extract archive, create directory, and upload files. All of these can be enacted on one or more files at a time (except rename). This module requires the client to have Java-script, and cookies enabled.

=head1 SPECIAL NOTES

If you use the OO interface for the file manager, make sure you instantiate the object BEFORE the header is sent! If you do not do this, Apache::FileManager can not store past cut and copied files inside a cookie.

Make sure the web server has read, write, and execute access access to the
directory you want to manage files in. Typically you are going to want to
run the following commands before you begin.

chown -R nobody /web/xyz/htdocs
chmod -R 755 /web/xyz/htdocs

The extract functionality only works with tarballs and zips. Is there demand for anything else?

=head1 BUGS

I am sure there are some bugs. All file operations refer to files using unix style filenames, so this probably won't work with windows. I did see a module that will abstract this for you so I might add windows operbility later.

=head1 TODO

It would be nice if you could choose a different base directory other then the document root in the constructor. I may do this sometime if I have a need to. If you want to contribute, send me your updates.

=head1 AUTHOR

Apache::FileManager was written by Philip Collins 
E<lt>pmc2@sr.unh.eduE<gt>.

=cut

use strict;
use warnings;
use Apache::Request;
use File::NCopy  qw(copy);
use File::Copy   qw(move);
use File::Remove qw(remove);
use File::stat;
use Archive::Any;
use POSIX qw(strftime);
use Storable qw(freeze thaw);
use MIME::Base64 qw(encode_base64 decode_base64);
use CGI::Cookie;
use Data::Dumper;

require 5.005_62;

our $VERSION = '0.01';

sub r      { return Apache::Request->instance( Apache->request ); }

#If this was called directly via a perl content handler by apache
sub handler {
  my $obj = __PACKAGE__->new();
  r->send_http_header('text/html');
  print "<HTML><HEAD><TITLE>File Manager</TITLE></HEAD>";
  $obj->print();
  print "</HTML>";
}


sub new {
  my $pack = shift;
  my $o = bless {}, $pack;


  #set some defaults (for warnings sake)
  r->param('FILEMANAGER_curr_dir'   => "") 
    unless defined r->param('FILEMANAGER_curr_dir');
  r->param('FILEMANAGER_action'     => "") 
    unless defined r->param('FILEMANAGER_action');
  r->param('FILEMANAGER_sel_files'  => []) 
    unless defined r->param('FILEMANAGER_sel_files');
  r->param('FILEMANAGER_rename'     => "") 
    unless defined r->param('FILEMANAGER_rename');
  r->param('FILEMANAGER_new_dir'    => "")
    unless defined r->param('FILEMANAGER_new_dir');


  #get copy and cut file arrays
  my ($cut_files, $copy_files);
  if (r->header_in('Cookie')) {
    my %cookies = CGI::Cookie->parse(r->header_in('Cookie'));
    my $server_name = r->server->server_hostname;
    if (exists $cookies{"$server_name FileManager"}) {
      my $ar = &destringify( $cookies{"$server_name FileManager"}->value );
      if (ref($ar) eq "ARRAY") {
        ($cut_files, $copy_files) = @{ $ar }; 
      }
    }
  }

  #document root
  my $dr = r->document_root;

  #verify current working directory
  $_ = r->param('FILEMANAGER_curr_dir');
  s/\.//g; s/^\///; s/\/$//;
  my $curr_dir = $_;
  
  #set current directory
  if (! chdir "$dr/$curr_dir") {
    chdir $dr;
    $curr_dir = "";
  }
  r->param('FILEMANAGER_curr_dir' => $curr_dir);

  #get names of selected files
  my @sel_files = r->param('FILEMANAGER_sel_files');
  

  #list selected files in copy buffer
  if (r->param('FILEMANAGER_action') eq "copy") {
    $cut_files = undef;
    $copy_files = \@sel_files;
  }

  
  #list selected files in cut buffer
  elsif (r->param('FILEMANAGER_action') eq "cut") {
    $copy_files = undef;
    $cut_files = \@sel_files;
  }

  #paste buffered files into current directory
  elsif (r->param('FILEMANAGER_action') eq "paste") {
    if (ref($copy_files) eq "ARRAY") {
      my @files = map { &fn_esc($dr."/".$_) } @{ $copy_files };
      copy \1, @files, ".";
    } elsif (ref($cut_files) eq "ARRAY") {
      for (@{ $cut_files }) {
        my $file = $dr."/".$_;
        if (-d $file) {
          my $file = &fn_esc($file);
          my $count = copy \1, $file, ".";
          if ($count) {
            remove \1, $file;
          }
        } elsif (-f $file) {
          move($file, ".");
        }
      }
    }
  }

  #delete selected files
  elsif (r->param('FILEMANAGER_action') eq "delete") {
    my @files = map { &fn_esc($dr."/".$_) } @sel_files;
    remove \1, @files;
  }

  #extract zip and tar balls into current directory
  elsif (r->param('FILEMANAGER_action') eq "extract") {
    foreach my $f (@sel_files) {
      my $esc = &fn_esc($dr."/".$f);
      my $archive = Archive::Any->new($esc);
      $archive->extract if defined $archive;
    }
  }

  #upload files into current directory
  elsif (r->param('FILEMANAGER_action') eq "upload") {
    foreach my $i (1 .. 10) {

      my @ar = split /\/|\\/, r->param("FILEMANAGER_file$i");
      next if ($#ar == -1);
      my $filename = pop @ar;
      $filename =~ s/[^\w\ \d\.]//g;
      next if ($filename eq "");

      my $up = r->upload("FILEMANAGER_file$i"); next if ! defined $up;
      my $in_fh = $up->fh; next if ! defined $in_fh;

      my $arg = "> ".$dr."/".r->param('FILEMANAGER_curr_dir')."/".$filename;
      my $out_fh = Apache::File->new($arg);

      next if ! defined $out_fh;

      while (<$in_fh>) {
        print $out_fh $_;
      }
    }
  }

  #rename the first selected file
  elsif ( (r->param('FILEMANAGER_action') eq "rename") && ($#sel_files > -1) ) {
    my $file = $dr."/".$sel_files[0];
    move($file, r->param('FILEMANAGER_rename'));
  }

  #this is some future to do stuff (rsync htdocs to a production server)
  elsif (r->param('FILEMANAGER_action') eq "go live") {
  

  }

  #create new directory in the current directory
  elsif (r->param('FILEMANAGER_action') eq "mkdir") {
    mkdir r->param('FILEMANAGER_new_dir');
  }

  
  #send copy and cut file arrays in a cookie
  my $encoded = &stringify([$cut_files, $copy_files]);
  my $server_name = r->server->server_hostname;
  my $cookie = new CGI::Cookie(-name=>"$server_name FileManager", -value=>$encoded);
  r->headers_out->add('Set-Cookie' => $cookie);

  return $o;
}

  

sub print {
  my $o = shift;

  #special case if this was a file upload submit 
  #just update the opener and close the file upload window
  if (r->param('FILEMANAGER_action') eq "upload") {
    print "<SCRIPT>window.opener.document.FileManager.submit(); window.opener.focus(); window.close();</SCRIPT>";
    return undef;
  }

  #This is future code for rsync functionality
  #<TD><A HREF=# style='text-decoration:none'><FONT COLOR=WHITE><B>go live!</B></FONT></A></TD>

  print "
<SCRIPT>
  function print_upload () {
    var w = window.open('','FileManagerUpload','scrollbars=yes,resizable=yes,width=360,height=440');
    var d = w.document.open();
    d.write(\"<HTML><BODY><CENTER><H1>Upload Files</H1><FORM NAME=UploadForm ACTION='".r->uri."' METHOD=POST onsubmit='window.opener.focus();' ENCTYPE=multipart/form-data><INPUT TYPE=HIDDEN NAME=FILEMANAGER_curr_dir VALUE='".r->param('FILEMANAGER_curr_dir')."'>\");
    for (var i=1; i <= 10; i++) {
      d.write(\"<INPUT TYPE=FILE NAME=FILEMANAGER_file\"+i+\"><BR>\");
    }
    d.write(\"<INPUT TYPE=SUBMIT NAME=FILEMANAGER_action VALUE=upload></CENTER></BODY></HTML>\");
    w.document.close();
    w.focus();
  }
</SCRIPT>

<FORM NAME=FileManager ACTION='".r->uri."' METHOD=POST>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_curr_dir VALUE='".r->param('FILEMANAGER_curr_dir')."'>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_action VALUE=''>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_new_dir VALUE=''>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_rename VALUE=''>

<H1>File Manager</H1>

<TABLE CELLPADDING=4 CELLSPACING=0 BORDER=0 WIDTH=100%>



<!-- Actions Tool bar -->
<TR>
<TD BGCLOLR=WHITE><TABLE CELLPADDING=6 CELLSPACING=2><TR BGCOLOR=BLACK ALIGN=CENTER>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.submit();\" style='text-decoration:none'><FONT COLOR=WHITE><B>refresh</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='cut'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>cut</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='copy'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>copy</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='paste'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>paste</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='delete'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>delete</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='rename'; f.FILEMANAGER_rename.value=window.prompt('enter new name',''); f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>rename</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='extract'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>extract</B></FONT></A></TD>
  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='mkdir'; f.FILEMANAGER_new_dir.value=window.prompt('new directory name',''); f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>new directory</B></FONT></A></TD>
  <TD><A HREF=# style='text-decoration:none' onclick=\"window.print_upload(); return false;\"><FONT COLOR=WHITE><B>upload<B></FONT></A></TD>

</TD></TR></TABLE></TD>
</TR>

<!-- location bar -->
<TR>
<TD><B>location: </B>".$o->dir_link_ctl."</TD>
</TR>


<!-- Files list -->
<TR>
<TD><TABLE CELLPADDING=3 CELLSPACING=0 WIDTH=100% BORDER=0>

<!-- Headers -->
<TR BGCOLOR=#606060>
<TD WIDTH=1%>&nbsp;</TD>
<TD WIDTH=80%><FONT COLOR=WHITE><B>filename</B></FONT></TD>
<TD WIDTH=15% ALIGN=CENTER><FONT COLOR=WHITE><B>last modified</B></FONT></TD>
<TD WIDTH=4% ALIGN=CENTER><FONT COLOR=WHITE><B>size</B></FONT></TD>
</TR>";

  my $bgcolor = "efefef";

  #get the list in this directory
  my $curr_dir = "";
  $curr_dir = r->param('FILEMANAGER_curr_dir')."/" 
    if (r->param('FILEMANAGER_curr_dir') ne "");
    
  my $count = 0;
  foreach my $file (sort <*>) {
    $count++;

    my ($link,$last_modified,$size);

    #if directory? 
    if (-d $file) {
      $link = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$curr_dir"."$file'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=#006699>$file</FONT></A>";
      $last_modified = "--";
      $size = "<TD ALIGN=CENTER>--</TD>";
    }

    #must be a file
    elsif (-f $file) {
    
      #get file size
      my $stat = stat($file);
      $size = $stat->size;
      if ($size > 1024000) {
        $size = sprintf("%0.2f",$size/1024000) . " <I>M</I>";
      } elsif ($stat->size > 1024) {
        $size = sprintf("%0.2f",$size/1024). " <I>K</I>";
      } else {
        $size = sprintf("%.2f",$size). " <I>b</I>";
      } 
      $size =~ s/\.0{1,2}//;
      $size = "<TD NOWRAP ALIGN=RIGHT>$size</TD>";

      #get last modified
      $last_modified = strftime "%D", localtime($stat->mtime);

      $link = "<A HREF=\"/$curr_dir"."$file?nossi=1\" TARGET=_blank style='text-decoration:none'><FONT COLOR=BLACK>$file</FONT></A>";
    }

    print "
<TR BGCOLOR=#$bgcolor>
<TD><INPUT TYPE=CHECKBOX NAME=FILEMANAGER_sel_files VALUE='$curr_dir"."$file'></TD>
<TD>$link</TD>
<TD ALIGN=CENTER>$last_modified</TD>
$size
</TR>";

    #alternate bgcolor so it is easier to read
    $bgcolor = ( ($bgcolor eq "ffffff") ? "efefef" : "ffffff" );
  }

  #print a message if there were no files in this directory
  if ($count == 0) {
    print "<TR ALIGN=CENTER><TD COLSPAN=3><TABLE BORDER=1 WIDTH=100%><TR><TD ALIGN=CENTER><BR><I>no files found</I><BR><BR></TD></TR></TABLE></TD></TR>";
  }

  print "
</TABLE>
</TD></TR>
<TR><TD><HR WIDTH=100%></TD></TR>
</TABLE>
</FORM>";
  return undef;
}



#return html directory location control
sub dir_link_ctl {
  my $o = shift;

  my @loc = split /\//, r->param('FILEMANAGER_curr_dir');

  #already in base directory?
  return "/" if ($#loc == -1);

  #for all elements in the loc except the last one
  my @ac;
  for (my $i = 0; $i < $#loc; $i++) {
    push @ac, $loc[$i];
    my $url = join("/", @ac);
    $loc[$i] = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$url'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=#006699>".$loc[$i]."</FONT></A>";
  }

  return "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value=''; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=#006699 SIZE=+1><B>/</B></FONT></A>&nbsp;".join("/&nbsp;", @loc);
}


#create a string representation of the perl structure
sub stringify {
  my $ref = shift;
  my $rv;
  eval {
    $rv = encode_base64(freeze($ref),"");
  }; if ($@) {
    warn $@;
    return undef;
  }
  return $rv;
}

#create the structure from the string representation
sub destringify {
  my $arg = shift || return undef;
  my $rv;
  eval {
    $rv = thaw(decode_base64($arg));
  };
  warn $@ if $@;
  return $rv;
}

#escape spaces in filename
sub fn_esc {
  my $f = shift;
  $f =~ s/\ /\\\ /g;
  return $f;
}
  



1;
