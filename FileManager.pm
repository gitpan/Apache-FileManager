package Apache::FileManager;


=head1 NAME

Apache::FileManager - apache mod_perl file manager

=head1 SYNOPSIS

Install in mod_perl enabled apache conf file
     <Location /FileManager>
       SetHandler           perl-script
       PerlHandler          Apache::FileManager
     </Location>

Or call from your own mod_perl script
  use Apache::FileManager;
  my $obj = Apache::FileManager->new();
  $obj->print();

=head1 DESCRIPTION

The Apache::FileManager module is a simple HTML file manager. It provides file manipulations such as cut, copy, paste, delete, rename, extract archive, create directory, and upload files. The interface is clean and simple, and configuration is a breeze.

For those of you who are up to the challenge, you can configure Apache::FileManager on run on a development server and update your live server htdocs tree with the click on a button. 

=head1 PREREQUISITES 

  The following (non-code) perl modules must be installed before installing Apache::FileManager.

      Apache::Request => 1.00
      File::NCopy     => 0.32
      File::Remove    => 0.20
      Archive::Any    => 0.03
      CGI::Cookie     => 1.20

=head1 SPECIAL NOTES

Make sure the web server has read, write, and execute access access to the
directory you want to manage files in. Typically you are going to want to
run the following commands before you begin.

chown -R nobody /web/xyz/htdocs
chmod -R 755 /web/xyz/htdocs

The extract functionality only works with tarballs and zips.

=head1 RSYNC FEATURE

To use the rync functionality you must have ssh, rsync, and the File::Rsync perl module installed on the development server. You also must have an sshd running on the production server.

Make sure you always fully qualify your server names so you don't have different values in your known hosts file.
for example:
ssh my-machine                -  wrong
ssh my-machine.subnet.com     -  right

Note: if the ip address of the production_server changes you will need a new known_hosts file.



To get the rsync feature to work do the following:

  #1 log onto the production server

  #2 become root

  #3 give web server user (typically nobody) a home area
     I made mine /usr/local/apache/nobody
     - production_server> mkdir /usr/local/apache/nobody
     - edit passwd file and set new home area for nobody
     - production_server> mkdir /usr/local/apache/nobody/.ssh

  #4 log onto the development server

  #5 become root

  #6 give web server user (typically nobody) a home area
     - dev_server> mkdir /usr/local/apache/nobody
     - dev_server> chown -R nobody.nobody /usr/local/apache/nobody
     - edit passwd file and set new home area for nobody
     - dev_server> su - nobody
     - dev_server> ssh-keygen -t dsa      (don't use passphrase)
     - dev_server> ssh production_server (will fail but will make known_hosts file)
     - log out from user nobody back to root user
     - dev_server> cd /usr/local/apache/nobody/.ssh
     - dev_server> scp id_dsa.pub production_server:/usr/local/apache/nobody/.ssh/authorized_keys
     - dev_server> chown -R nobody.nobody /usr/local/apache/nobody
     - dev_server> chmod -R 700 /usr/local/apache/nobody

  #7 log back into the production server

  #8 become root

  #9 Do the following commands:
     - production_server> chown -R nobody.nobody /usr/local/apache/nobody
     - production_server> chmod -R 700 /usr/local/apache/nobody

You also need to specify the production server in the development server's web conf file. So your conf file should look like this:

     <Location /FileManager>
       SetHandler           perl-script
       PerlHandler          Apache::FileManager
       PerlSetVar           RSYNC_TO   production_server:/web/xyz
     </Location>

If your ssh path is not /usr/bin/ssh or /usr/local/bin/ssh, you also need to specify the path in the conf file or in the contructor with the directive SSH_PATH.

You can also specify RSYNC_TO in the constructor:
my $obj = Apache::FileManager->new({ RSYNC_TO => "production_server:/web/xyz" });

Also make sure /web/xyz and all files in the tree are readable, writeable, and executable by nobody on both the production server AND the development server.


=head1 BUGS

I am sure there are some.

=head1 TODO

It would be nice if you could choose a different base directory other then the document root in the constructor. I may do this sometime if I have a need to. If you want to contribute, let me know.

=head1 AUTHOR

Apache::FileManager was written by Philip Collins 
E<lt>pmc@cpan.orgE<gt>.

=cut

use strict;
use warnings;
use Apache::Request;
use Apache::File;
use File::NCopy  qw(copy);
use File::Copy   qw(move);
use File::Remove qw(remove);
use File::stat;
use Archive::Any;
use POSIX qw(strftime);
use CGI::Cookie;
#use Data::Dumper;

require 5.005_62;

our $VERSION = '0.06';

sub r      { return Apache::Request->instance( Apache->request ); }

#If this was called directly via a perl content handler by apache
sub handler {
  my $obj = __PACKAGE__->new();
  r->send_http_header('text/html');
  print "<HTML><HEAD><TITLE>".r->server->server_hostname." File Manager $VERSION</TITLE></HEAD><FONT SIZE=+2><B>".r->server->server_hostname." File Manager $VERSION</B></FONT><BR>";
  $obj->print();
  print "</HTML>";
}


sub new {
  my $pack = shift;
  my $ref = shift || {};


  my $o = bless $ref, $pack;

  $$o{MESSAGE} = "";
  $$o{JS} = "";

  # Is this filemanager rsync capable?
  $$o{'RSYNC_TO'} ||= r->dir_config('RSYNC_TO');


  #set some defaults (for warnings sake)
  r->param('FILEMANAGER_curr_dir'   => "") 
    unless defined r->param('FILEMANAGER_curr_dir');
  r->param('FILEMANAGER_action'     => "") 
    unless defined r->param('FILEMANAGER_action');
  r->param('FILEMANAGER_rename'     => "") 
    unless defined r->param('FILEMANAGER_rename');
  r->param('FILEMANAGER_new_dir'    => "")
    unless defined r->param('FILEMANAGER_new_dir');
  r->param('FILEMANAGER_sel_files'  => [])
    unless defined r->param('FILEMANAGER_sel_files');

  #get names of selected files
  my @sel_files = r->param('FILEMANAGER_sel_files');


  #get copy and cut file arrays
  $$o{buffer_type} = "";
  $$o{buffer_filenames} = [];
  if (r->header_in('Cookie')) {
    my $cookie_name = uc(r->server->server_hostname);
    $cookie_name =~ s/[^A-Z]//g;
    $cookie_name .= "_FM";
    my %cookies = CGI::Cookie->parse(r->header_in('Cookie'));
    if (exists $cookies{$cookie_name}) {
      my $data = $cookies{$cookie_name}->value;
      my @ar = split /\|/, $data;

      #is there something in buffer
      if ($#ar > 0) {
        $$o{buffer_type}      = pop @ar;
        $$o{buffer_filenames} = \@ar;
      }
    }
  }


  #document root
  my $dr = r->document_root;


  #verify current working directory
  $_ = r->param('FILEMANAGER_curr_dir');
  s/\.\.//g; s/^\///; s/\/$//;
  my $curr_dir = $_;

  #set current directory
  if (! chdir "$dr/$curr_dir") {
    chdir $dr;
    $curr_dir = "";
  }
  r->param('FILEMANAGER_curr_dir' => $curr_dir);


  #paste buffered files into current directory
  if (r->param('FILEMANAGER_action') eq "paste") {
    if ($$o{buffer_type} eq "copy") {
      my @files = map { &fn_esc($dr."/".$_) } @{ $$o{buffer_filenames} };
      my $count = copy \1, @files, ".";
      $$o{MESSAGE} = "$count file(s) pasted.";
    } elsif ($$o{buffer_type} eq "cut") {
      for (@{ $$o{buffer_filenames} }) {
        my $file = $dr."/".$_;
        if (-d $file) {
          my $file = &fn_esc($file);
          my $count = copy \1, $file, ".";
          if ($count) {
            remove \1, $file;
          }
          $$o{MESSAGE} = "$count file(s) pasted.";
        } elsif (-f $file) {
          my $count = move($file, ".");
          $$o{MESSAGE} = "$count file(s) pasted.";
        }
      }
    }
    $$o{JS} = "window.setcookie(cookie_name,'',-1);";
  }

  #delete selected files
  elsif (r->param('FILEMANAGER_action') eq "delete") {
    my @files = map { &fn_esc($dr."/".$_) } @sel_files;
    my $count = remove \1, @files;
    $$o{MESSAGE} = "$count file(s) deleted.";
  }

  #extract zip and tar balls into current directory
  elsif (r->param('FILEMANAGER_action') eq "extract") {
    foreach my $f (@sel_files) {
      my $esc = &fn_esc($dr."/".$f);
      my $archive = Archive::Any->new($esc);
      $archive->extract if defined $archive;
      $$o{MESSAGE} = "Files extracted.";
    }
  }

  #upload files into current directory
  elsif (r->param('FILEMANAGER_action') eq "upload") {
    my $count = 0;
    foreach my $i (1 .. 10) {

      my @ar = split /\/|\\/, r->param("FILEMANAGER_file$i");
      next if ($#ar == -1);
      my $filename = pop @ar;
      $filename =~ s/[^\w\ \d\.\-]//g;
      next if ($filename eq "");

      $count++;

      my $up = r->upload("FILEMANAGER_file$i"); next if ! defined $up;
      my $in_fh = $up->fh; next if ! defined $in_fh;

      my $arg = "> ".$dr."/".r->param('FILEMANAGER_curr_dir')."/".$filename;
      my $out_fh = Apache::File->new($arg);

      next if ! defined $out_fh;

      while (<$in_fh>) {
        print $out_fh $_;
      }
    }
    $$o{MESSAGE} = "$count file(s) uploaded.";
  }

  #rename the first selected file
  elsif ( (r->param('FILEMANAGER_action') eq "rename") && ($#sel_files > -1) ) {
    my $file = $dr."/".$sel_files[0];
    my $bool = move($file, r->param('FILEMANAGER_rename'));
    if ($bool) {
      $$o{MESSAGE} = "File renamed.";
    } else {
      $$o{MESSAGE} = "File could not be renamed.";
    }
  }

  #rsync (go live!) feature
  elsif (r->param('FILEMANAGER_action') eq "rsync") {
    $$o{'SSH_PATH'} ||= r->dir_config('SSH_PATH');

    #try some default paths for ssh if we can't find ssh
    for (qw(/usr/bin/ssh /usr/local/bin/ssh)) {
      last if $$o{'SSH_PATH'};
      $$o{'SSH_PATH'} = $_ if (-f $_);
    }

    eval "require File::Rsync";
    if ($@) {
      r->log_error($@);
      $$o{MESSAGE} = "Module File::Rsync not installed.";
    } else {   
      my $obj = File::Rsync->new( {
        'archive'    => 1,
        'compress'   => 1,
        'rsh'        => $$o{'SSH_PATH'},
        'delete'     => 1,
        'stats'      => 1
      } );

      $obj->exec( { src  => r->document_root, 
                    dest => $$o{'RSYNC_TO'}    } ) 
        or warn "rsyn failed\n";
      $$o{MESSAGE} = join ("<BR>", @{ $obj->out }) if ($obj->out);
      $$o{MESSAGE} = join ("<BR>", @{ $obj->err }) if ($obj->err);
    }
  }

  #create new directory in the current directory
  elsif (r->param('FILEMANAGER_action') eq "mkdir") {
    my $bool = mkdir r->param('FILEMANAGER_new_dir');
    if ($bool) {
      $$o{MESSAGE} = "New directory added.";
    } else {
      $$o{MESSAGE} = "Could not make directory.";
    }
  }

  
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

  #special case if this was an rsync 
  #just display the message with a close button
  elsif (r->param('FILEMANAGER_action') eq "rsync") {
    print "<CENTER><TABLE CELLPADDING=0 CELLSPACING=0 BORDER=0><TR><TD>$$o{MESSAGE}</TD></TR><TR><FORM><TD ALIGN=RIGHT><INPUT TYPE=BUTTON VALUE='close' onclick=\"window.close();\"></TD></FORM></TR></TABLE></CENTER>";
    return undef;
  }

  my $rsync = "";
  if (exists $$o{'RSYNC_TO'}) {
    $rsync = "<TD><A HREF=# style='text-decoration:none' onclick=\"if (window.confirm('Are you sure you want to synchronize with the production server?')) {var w=window.open('','RSYNC','scrollbars=yes,resizables=yes,width=400,height=500'); w.focus(); var d=w.document.open(); d.write('<HTML><BODY><BR><BR><BR><CENTER>Please wait synchronizing production server.<BR>This could take several minutes.</CENTER></BODY></HTML>'); d.close(); w.location.replace('".r->uri."?FILEMANAGER_action=rsync','RSYNC','scrollbars=yes,resizables=yes,width=400,height=500'); } return false;\"><FONT COLOR=WHITE><B>go live!</B></FONT></A></TD>";
  }

  my $cookie_name = uc(r->server->server_hostname);
  $cookie_name =~ s/[^A-Z]//g;
  $cookie_name .= "_FM";

  my $message = "<I><FONT COLOR=#990000>".$$o{MESSAGE}."</FONT></I>";

  print "
$message
<SCRIPT>
  var cookie_name = '$cookie_name';

  function getexpirydate(nodays){
    var UTCstring;
    Today = new Date();
    nomilli=Date.parse(Today);
    Today.setTime(nomilli+nodays*24*60*60*1000);
    UTCstring = Today.toUTCString();
    return UTCstring;
  }

  function getcookie(cookiename) {
    var cookiestring=''+document.cookie;
    var index1=cookiestring.indexOf(cookiename);
    if (index1==-1 || cookiename=='') return ''; 
    var index2=cookiestring.indexOf(';',index1);
    if (index2==-1) index2=cookiestring.length; 
    return unescape(cookiestring.substring(index1+cookiename.length+1,index2));
  }
  
  function setcookie(name,value,duration){
    cookiestring=name+'='+escape(value)+';EXPIRES='+getexpirydate(duration);
    document.cookie=cookiestring;
    if(!getcookie(name)){ return false; }
    else{ return true; }
  }

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

  // make input check box form elements into an array ALL the time
  function get_ckbox_array() {
    var ar;

    // no files
    if (window.document.FileManager.FILEMANAGER_sel_files == null) {
      ar = new Array();
    }

    // 1 file (no length)
    else if (window.document.FileManager.FILEMANAGER_sel_files.length == null){
      ar = [ window.document.FileManager.FILEMANAGER_sel_files ]; 
    }

    // more than one file
    else {
      ar = window.document.FileManager.FILEMANAGER_sel_files;
    }
    return ar;
  }

  // get the number checked
  function get_num_checked() {
    var count = 0;
    var ar = get_ckbox_array();
    for (var i=0; i < ar.length; i++) {
      if (ar[i].checked == true) {
        count++;
      }
    }
    return count;
  }

  // make cookie for checked filenames
  function save_names (type) {
    var cb = get_ckbox_array();
    var ac = '';
    for (var i=0; i < cb.length; i++) {
      if (cb[i].checked == true) {
        ac = ac + cb[i].value + '|';
        cb[i].checked = false;
      }
    }
    if (ac == '') {
      window.alert('Please select file(s) by clicking on the check boxes with the mouse.');
    } else {
      ac = ac + type;
      window.setcookie(cookie_name,ac,1);
    }
  }

  //test if browser cookies are enabled
  if (! window.document.cookie ) {
    window.setcookie(cookie_name,'test',1);
    if (! window.document.cookie) document.write('<H1><FONT COLOR=#990000>please enable cookies</FONT></H1>');
    window.setcookie(cookie_name,'',-1);
  } 

$$o{JS}

</SCRIPT>

<NOSCRIPT>
  <H1><FONT COLOR=#990000>please enable javascript</FONT></H1>
</NOSCRIPT>

<FORM NAME=FileManager ACTION='".r->uri."' METHOD=POST>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_curr_dir VALUE='".r->param('FILEMANAGER_curr_dir')."'>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_action VALUE=''>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_new_dir VALUE=''>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_rename VALUE=''>


<TABLE CELLPADDING=4 CELLSPACING=0 BORDER=0 WIDTH=100%>



<!-- Actions Tool bar -->
<TR>
<TD BGCLOLR=WHITE><TABLE CELLPADDING=6 CELLSPACING=2><TR BGCOLOR=BLACK ALIGN=CENTER>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.submit();\" style='text-decoration:none'><FONT COLOR=WHITE><B>refresh</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"window.save_names('cut'); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>cut</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"window.save_names('copy'); return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>copy</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"if (window.getcookie(cookie_name) != '') { var f=window.document.FileManager; f.FILEMANAGER_action.value='paste'; f.submit(); } else { window.alert('Please select file(s) to paste by checking the file(s) first and clicking copy or cut.'); } return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>paste</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; if (get_num_checked() == 0) { window.alert('Please select a file to delete by clicking on a check box with the mouse.'); } else { f.FILEMANAGER_action.value='delete'; f.submit(); } return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>delete</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; if (get_num_checked() == 0) { window.alert('Please select a file to rename by clicking on a check box with the mouse.'); } else { f.FILEMANAGER_action.value='rename'; var rv=window.prompt('enter new name',''); if ((rv != null)&&(rv != '')) { f.FILEMANAGER_rename.value=rv; f.submit(); } } return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>rename</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; if (get_num_checked() == 0) { window.alert('Please select a file to extract by clicking on a check box with the mouse.'); } else { f.FILEMANAGER_action.value='extract'; f.submit(); } return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>extract</B></FONT></A></TD>

  <TD><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_action.value='mkdir'; var rv=window.prompt('new directory name',''); if ((rv != null)&&(rv != '')) { f.FILEMANAGER_new_dir.value=rv; f.submit(); } return false;\" style='text-decoration:none'><FONT COLOR=WHITE><B>new directory</B></FONT></A></TD>
  <TD><A HREF=# style='text-decoration:none' onclick=\"window.print_upload(); return false;\"><FONT COLOR=WHITE><B>upload<B></FONT></A></TD>
$rsync

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
  return "<B>/</B>" if ($#loc == -1);

  #for all elements in the loc except the last one
  my @ac;
  for (my $i = 0; $i < $#loc; $i++) {
    push @ac, $loc[$i];
    my $url = join("/", @ac);
    $loc[$i] = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$url'; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=#006699 SIZE=+1><B>".$loc[$i]."</B></FONT></A>";
  }

  $loc[$#loc] = "<B><FONT SIZE=+1>".$loc[$#loc]."</FONT></B>";

  return "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value=''; f.submit(); return false;\" style='text-decoration:none'><FONT COLOR=#006699 SIZE=+1><B>/</B></FONT></A>&nbsp;".join("/&nbsp;", @loc);
}


#escape spaces in filename
sub fn_esc {
  my $f = shift;
  $f =~ s/\ /\\\ /g;
  return $f;
}
  



1;
