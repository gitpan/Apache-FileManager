package Apache::FileManager;


=head1 NAME

Apache::FileManager - apache mod_perl file manager

=head1 SYNOPSIS


- Install in mod_perl enabled apache conf file
     <Location /FileManager>
       SetHandler           perl-script
       PerlHandler          Apache::FileManager
     </Location>


- Or call from your own mod_perl script
  use Apache::FileManager;
  my $obj = Apache::FileManager->new();
  $obj->print();


- Or create your own custom MyFileManager subclass
package MyFileManager;
use strict;
use Apache::FileManager;

our @ISA = ('Apache::FileManager');

sub handler {
  my $r = shift;
  my $obj = __PACKAGE__->new();
  $r->send_http_header('text/html');
  print "<HTML><HEAD><TITLE>".$r->server->server_hostname." File Manager</TITLE>
</HEAD>";
  $obj->print();
  print "</HTML>";
}

.. overload the methods ..


=head1 DESCRIPTION

The Apache::FileManager module is a simple HTML file manager. It provides file manipulations such as cut, copy, paste, delete, rename, extract archive, create directory, and upload files. The interface is clean and simple, and configuration is a breeze.

For those of you who are up to the challenge, you can configure Apache::FileManager on run on a development server and update your live server htdocs tree with the click on a button. 

=head1 PREREQUISITES 

  The following (non-core) perl modules must be installed before installing Apache::FileManager.

      Apache::Request => 1.00
      Apache::File    => 1.01
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


=head1 USING DIFFERENT DOCUMENT ROOT

You can specify a different document root as long as the new document root falls inside of the orginal document root. For example if the document root of a web server is /web/project/htdocs, you could assign the document root to also be /web/project/htdocs/newroot. The directory `newroot` must exist.

- Specify different document root in apache conf file
     <Location /FileManager>
       SetHandler           perl-script
       PerlHandler          Apache::FileManager
       PerlSetVar           DOCUMENT_ROOT /web/project/htdocs/newroot
     </Location>

- Or specify different document root in your own mod_perl script
  use Apache::FileManager;
  my $obj = Apache::FileManager->new({ DOCUMENT_ROOT => '/web/project/htdocs/newroot' });
  $obj->print();

=head1 SUBCLASSING Apache::FileManager 

Create a new file with the following code:

package MyProject::MyFileManager;
use strict;
use Apache::FileManager;
our @ISA = ('Apache::FileManager');

  #Add your own methods here

1;

The best way to subclass the filemanager would be to copy the methods you want to overload from the Apache::FileManager file to your new subclass. Then change the methods to your liking. If you think you have a great extension, or you feel like you did something better, email me your subclass and I'll merge the relevant parts to the main code.

=head1 TO DO

I need to write documentation on the different methods. Maybe someone else wants to do this.

=head1 BUGS

There is a bug in File::NCopy that occurs when trying to paste an empty directory. The directory is copied but reports back as 0 directories pasted. The author is in the process of fixing the problem.

=head1 AUTHOR

Apache::FileManager was written by Philip Collins 
E<lt>pmc@cpan.orgE<gt>.

=cut

use strict;
#use warnings;
use Apache::Request;
use Apache::File;
use File::NCopy  qw(copy);
use File::Copy   qw(move);
use File::Remove qw(remove);
use File::stat;
use Archive::Any;
use POSIX qw(strftime);
use CGI::Cookie;
use Apache::Constants ':common';
#use Data::Dumper;

require 5.005_62;

our $VERSION = '0.17';

sub r  { return Apache::Request->instance( Apache->request ); }


# ---------- Object Constructor -----------------------------------------
sub new {
  my $package = shift;
  my $attribs = shift || {};
  my $o = bless $attribs, $package;
  $o->intialize();
  $o->execute_cmds();
  return $o;
}




# ---- If this was called directly via a perl content handler by apache -------
sub handler {
  return DECLINED if defined r->param('nossi');
  my $package = __PACKAGE__;
  my $obj = $package->new();
  r->send_http_header('text/html');
  print "<HTML><HEAD><TITLE>".r->server->server_hostname." File Manager $VERSION</TITLE></HEAD>";
  $obj->print();
  print "</HTML>";
  return OK;
}



# ---- Call the view ----------------------------------------------
sub print {
  my $o = shift;
  my $view = "view_".$$o{'view'};
  $o->$view();
}

# ------------ Intialize object -----------------------------------------
sub intialize {
  my $o = shift;

  $$o{MESSAGE} = "";
  $$o{JS} = "";


  # Is this filemanager rsync capable?
  $$o{'RSYNC_TO'} ||= r->dir_config('RSYNC_TO') || undef;

  #set some defaults (for warnings sake)
  r->param('FILEMANAGER_cmd'   => "") 
    unless defined r->param('FILEMANAGER_cmd');
  r->param('FILEMANAGER_arg'     => "") 
    unless defined r->param('FILEMANAGER_arg');
  r->param('FILEMANAGER_curr_dir'   => "") 
    unless defined r->param('FILEMANAGER_curr_dir');
  r->param('FILEMANAGER_sel_files'  => [])
    unless defined r->param('FILEMANAGER_sel_files');


  #document root
  my $dr = r->document_root;
  $$o{DR} ||= r->dir_config('DOCUMENT_ROOT') || r->document_root;

  #does user defined document root lie inside real doc root?
  if ($$o{DR} !~ /^$dr/) {
    $$o{DR} = r->document_root;
    r->log_error("Warning: Document root changed to $dr. Custom document root must lie inside of real document root.");
  }

  #verify current working directory
  $_ = r->param('FILEMANAGER_curr_dir');
  s/\.\.//g; s/^\///; s/\/$//;
  my $curr_dir = $_;

  #set current directory
  if (! chdir $$o{DR}."/$curr_dir") {
    chdir $$o{DR};
    $curr_dir = "";
  }
  r->param('FILEMANAGER_curr_dir' => $curr_dir);

  #set default view method
  $$o{'view'} = "filemanager";

  return undef;
}





































###############################################################################
# ----- Views --------------------------------------------------------------- #
###############################################################################

#after upload files - view
sub view_post_upload {
  my $o = shift;
  print "<SCRIPT>window.opener.document.FileManager.submit(); window.opener.focus(); window.close();</SCRIPT>";
  return undef;
}


#after rsync transacation - view
sub view_post_rsync {
  my $o = shift;
  print "<CENTER><TABLE CELLPADDING=0 CELLSPACING=0 BORDER=0><TR><TD>$$o{MESSAGE}</TD></TR><TR><FORM><TD ALIGN=RIGHT><INPUT TYPE=BUTTON VALUE='close' onclick=\"window.close();\"></TD></FORM></TR></TABLE></CENTER>";
  return undef;
}


sub view_filemanager {
  my $o = shift;

  my $message = "<I><FONT COLOR=#990000>".$$o{MESSAGE}."</FONT></I>";

  my ($location, $up_a_href) = $o->html_location_toolbar();
  $up_a_href = "" if !defined($up_a_href);

  print "
    <!-- Scripts -->
    ".$o->html_javascript."

    <!-- Styles -->
    ".$o->html_style_sheet()."

    <FORM NAME=FileManager ACTION='".r->uri."' METHOD=POST>
    ".$o->html_hidden_fields()."

      <!-- Header -->
      ".$o->html_top()."

      <!-- Special message -->
      $message

      <TABLE CELLPADDING=2 CELLSPACING=2 BORDER=0 WIDTH=100% BGCOLOR=#606060>
        <TR><TD>".$o->html_cmd_toolbar()."</TD></TR>
        <TR BGCOLOR=WHITE><TD>$location</TD></TR>
        <TR><TD>".$o->html_file_list($up_a_href)."</TD></TR>
      </TABLE>

      <!-- Footer -->
      ".$o->html_bottom()."

    </FORM>";

  return undef;
}













































###############################################################################
# ---- HTML Component Output ------------------------------------------------ #
###############################################################################

sub html_javascript {
  my $o = shift;

  my $cookie_name = uc(r->server->server_hostname);
  $cookie_name =~ s/[^A-Z]//g;
  $cookie_name .= "_FM";

  #start return literal
  return "
  <NOSCRIPT>
    <H1><FONT COLOR=#990000>please enable javascript</FONT></H1>
  </NOSCRIPT>
  <SCRIPT>
  <!--
  var cookie_name = '$cookie_name';

  function display_help () {
    var w=window.open('','help','resizable=yes,scrollbars=yes,width=650,height=650');
    var d = w.document.open();
    d.write(\"<HTML> <UL><B><U><FONT SIZE=+1>Help</FONT></U></B><BR><BR>\"+

\"<LI><A NAME=upload><B>How do I upload files?</B></A><BR>\"+
\"Click on the upload menu item. After the <I>Upload Files</I> window opens, click the <I>Browse</I> button. This will pop open another window showing files on your computer. Select a file you want to upload. You can not upload directories. If you want to upload a directory, archive it first into a <I>zip</I> file or a tarball. You will then be able to extract it on the server. You can upload up to 10 files at a time. After selecting the files you want to upload, click the <I>upload</I> button to transfer the files from your machine to the server.<BR><BR>\"+

\"<LI><A NAME=move><B>How do I copy or move files?</B></A><BR>\"+
\"First click the check boxes next to the file names that you would like to copy or paste. Next click the <I>copy</I> or <I>paste</I> button. Then go to the directory you would like them pasted in. Finally, click <I>paste</I>.<BR><BR>\"+

\"<LI><A NAME=move><B>Why does the file manager seem broken in certain directories or when copying or pasting certain files?</B></A><BR>\"+
\"This occurs when the file manager does not have permission to access these files. To fix the problem, contact your system administrator and ask them to grant the webserver READ, WRITE, and EXECUTE access to your files.<BR><BR>\"+

\"</UL><CENTER><FORM><INPUT TYPE=BUTTON VALUE='close' onclick='window.close();'></FORM> </CENTER> </HTML>\");
    d.close();
    w.focus();
  }

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
    var w = window.open('','FileManagerUpload','scrollbars=yes,resizable=yes,width=500,height=440');
    var d = w.document.open();
    d.write(\"<HTML><BODY><CENTER><H1>Upload Files</H1><FORM NAME=UploadForm ACTION='".r->uri."' METHOD=POST onsubmit='window.opener.focus();' ENCTYPE=multipart/form-data><INPUT TYPE=HIDDEN NAME=FILEMANAGER_curr_dir VALUE='".r->param('FILEMANAGER_curr_dir')."'>\");
    for (var i=1; i <= 10; i++) {
      d.write(\"<INPUT TYPE=FILE SIZE=40 NAME=FILEMANAGER_file\"+i+\"><BR>\");
    }
    d.write(\"<INPUT TYPE=BUTTON VALUE='cancel' onclick='window.close();'>&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;<INPUT TYPE=SUBMIT NAME=FILEMANAGER_cmd VALUE=upload></CENTER></BODY></HTML>\");
    d.close();
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

  -->
  </SCRIPT> "; #end return literal

}
 ### end sub html_javascript

sub html_style_sheet {
  my $o = shift;

  return ("
  <STYLE TYPE='text/css'>
    <!-- 
      A { text-decoration: none; }
      A:hover	{ text-decoration: underline; }
    -->
  </STYLE>")
}




sub html_hidden_fields {
  my $o = shift;
  return "
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_curr_dir VALUE='".r->param('FILEMANAGER_curr_dir')."'>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_cmd VALUE=''>
<INPUT TYPE=HIDDEN NAME=FILEMANAGER_arg VALUE=''>";
}

sub html_location_toolbar {
  my $o = shift;

  my @loc = split /\//, r->param('FILEMANAGER_curr_dir');

  #already in base directory?
  return "<B>location: / </B>" if ($#loc == -1);

  #for all elements in the loc except the last one
  my @ac;
  my $up_a_href = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value=''; f.submit(); return false;\"><FONT COLOR=#006699 SIZE=+1><B>..</B></FONT></A>&nbsp;";
  for (my $i = 0; $i < $#loc; $i++) {
    push @ac, $loc[$i];
    my $url = join("/", @ac);
    $loc[$i] = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$url'; f.submit(); return false;\"><FONT COLOR=#006699 SIZE=+1><B>".$loc[$i]."</B></FONT></A>";
    if ($i == ($#loc - 1)) {
      $up_a_href = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$url'; f.submit(); return false;\"><FONT COLOR=#006699 SIZE=+1><B>..</B></FONT></A>&nbsp;";
    }
  }

  $loc[$#loc] = "<FONT SIZE=+1><B>".$loc[$#loc]."</B></FONT>";

  my $location = "<B>location: </B><A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value=''; f.submit(); return false;\"><FONT COLOR=#006699 SIZE=+1><B>/</B></FONT></A>&nbsp;".join("&nbsp;<FONT SIZE=+1><B>/</B></FONT>&nbsp;", @loc);

  return ($location, $up_a_href);
}

sub html_cmd_toolbar {
  my $o = shift;

  my @cmds = (

   #Refresh
   "<A HREF=# onclick=\"var f=window.document.FileManager; f.submit();\"><FONT COLOR=WHITE><B>refresh</B></FONT></A>",

   #Cut
   "<A HREF=# onclick=\"window.save_names('cut'); return false;\"><FONT COLOR=WHITE><B>cut</B></FONT></A>",

   #Copy
   "<A HREF=# onclick=\"window.save_names('copy'); return false;\"><FONT COLOR=WHITE><B>copy</B></FONT></A>",

   #Paste
  "<A HREF=# onclick=\"if (window.getcookie(cookie_name) != '') { var f=window.document.FileManager; f.FILEMANAGER_cmd.value='paste'; f.submit(); } else { window.alert('Please select file(s) to paste by checking the file(s) first and clicking copy or cut.'); } return false;\"><FONT COLOR=WHITE><B>paste</B></FONT></A>",

   #Delete
  "<A HREF=# onclick=\"
     var f=window.document.FileManager;
     if (get_num_checked() == 0) {
         window.alert('Please select a file to delete by clicking on a check box with the mouse.');
     }
     else {
         var msg = '\\n' +
                   '                 Are you sure?\\n' +
                   '\\n' +
                   'Click OK to delete selected files & directories\\n' +
                   '   ***including*** files in those directories';
         if (window.confirm(msg)) {
             f.FILEMANAGER_cmd.value='delete';
             f.submit();
         }
     }
     return false;
\"><FONT COLOR=WHITE><B>delete</B></FONT></A>",

  #Rename
  "<A HREF=# onclick=\"var f=window.document.FileManager; if (get_num_checked() == 0) { window.alert('Please select a file to rename by clicking on a check box with the mouse.'); } else { f.FILEMANAGER_cmd.value='rename'; var rv=window.prompt('enter new name',''); if ((rv != null)&&(rv != '')) { f.FILEMANAGER_arg.value=rv; f.submit(); } } return false;\"><FONT COLOR=WHITE><B>rename</B></FONT></A>",

  #Extract
  "<A HREF=# onclick=\"var f=window.document.FileManager; if (get_num_checked() == 0) { window.alert('Please select a file to extract by clicking on a check box with the mouse.'); } else { f.FILEMANAGER_cmd.value='extract'; f.submit(); } return false;\"><FONT COLOR=WHITE><B>extract</B></FONT></A>",

  #New Directory
  "<A HREF=# onclick=\"var f=window.document.FileManager; var rv=window.prompt('new directory name',''); if ((rv != null)&&(rv != '')) { f.FILEMANAGER_arg.value=rv; f.FILEMANAGER_cmd.value='mkdir'; f.submit(); } return false;\"><FONT COLOR=WHITE><B>new directory</B></FONT></A>",

  #Upload
  "<A HREF=# onclick=\"window.print_upload(); return false;\"><FONT COLOR=WHITE><B>upload<B></FONT></A>"
  );

  #Rsync
  my $rsync = "";
  if ($$o{'RSYNC_TO'}) {
    push @cmds, "<TD><A HREF=# onclick=\"if (window.confirm('Are you sure you want to synchronize with the production server?')) {var w=window.open('','RSYNC','scrollbars=yes,resizables=yes,width=400,height=500'); w.focus(); var d=w.document.open(); d.write('<HTML><BODY><BR><BR><BR><CENTER>Please wait synchronizing production server.<BR>This could take several minutes.</CENTER></BODY></HTML>'); d.close(); w.location.replace('".r->uri."?FILEMANAGER_cmd=rsync','RSYNC','scrollbars=yes,resizables=yes,width=400,height=500'); } return false;\"><FONT COLOR=WHITE><B>synchronize</B></FONT></A>";
  }

  return "
<!-- Actions Tool bar -->
<TABLE CELLPADDING=0 CELLSPACING=0 BORDER=0><TR ALIGN=CENTER><TD ALIGN=CENTER>".join("</TD><TD>&nbsp;<B><FONT COLOR=#bcbcbc SIZE=+2>|</FONT>&nbsp;</B></TD><TD>", @cmds)."</TD></TR></TABLE>";

}

sub html_file_list {
  my $o = shift;
  my $up_a_href = shift || "";

  my $bgcolor = "efefef";

  #get the list in this directory
  my $curr_dir = "";
  $curr_dir = r->param('FILEMANAGER_curr_dir')."/"
    if (r->param('FILEMANAGER_curr_dir') ne "");

  #if there is a value for the ".." directory, then add a row for that link
  #at the *top* of the list
  my $acum = "";
  if ($up_a_href ne "") {
    $acum = "
<TR BGCOLOR=#$bgcolor>
<TD>&nbsp;</TD>
<TD>$up_a_href</TD>
<TD ALIGN=CENTER>--</TD>
<TD ALIGN=CENTER>--</TD>
</TR>";
    $bgcolor = "ffffff";
  }

  my $ct_rows = 0;

  foreach my $file (sort <*>) {

    my ($link,$last_modified,$size,$type);
    $ct_rows++;

    #if directory?
    if (-d $file) {
      $last_modified = "--";
      $size = "<TD ALIGN=CENTER>--</TD>";
      $type = "/"; # "/" designates "directory"
      $link = "<A HREF=# onclick=\"var f=window.document.FileManager; f.FILEMANAGER_curr_dir.value='$curr_dir"."$file'; f.submit(); return false;\"><FONT COLOR=#006699>$file$type</FONT></A>";
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
      $last_modified = $o->formated_date($stat->mtime);

      #get file type
      if (-S $file) {
        $type = "="; # "=" designates "socket"
      }
      elsif (-l $file) {
        $type = "@"; # "@" designates "link"
      }
      elsif (-x $file) {
        $type = "*"; # "*" designates "executable"
      }

      my $true_doc_root = r->document_root;
      my $fake_doc_root = $$o{DR};
      $fake_doc_root =~ s/^$true_doc_root//;
      $fake_doc_root =~ s/^\///; $fake_doc_root =~ s/\/$//;

      my $href = $curr_dir;
      $href = $fake_doc_root."/".$href if $fake_doc_root;

      $link = "<A HREF=\"/$href"."$file?nossi=1\" TARGET=_blank><FONT COLOR=BLACK>$file$type</FONT></A>";
    }

    $acum .= "
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
  if ($ct_rows == 0) {
    $acum .= "<TR ALIGN=CENTER><TD COLSPAN=3><TABLE BORDER=1 WIDTH=100% BGCOLOR=WHITE><TR><TD ALIGN=CENTER><BR><I>no files found</I><BR><BR></TD></TR></TABLE></TD></TR>";
  }

  return "
<!-- Files list -->
<TABLE CELLPADDING=3 CELLSPACING=0 WIDTH=100% BORDER=0>

<!-- Headers -->
<TR BGCOLOR=#606060>
<TD WIDTH=1%>&nbsp;</TD>
<TD WIDTH=80%><FONT COLOR=WHITE><B>filename</B></FONT></TD>
<TD WIDTH=15% ALIGN=CENTER NOWRAP><FONT COLOR=WHITE><B>last modified</B></FONT></TD>
<TD WIDTH=4% ALIGN=CENTER><FONT COLOR=WHITE><B>size</B></FONT></TD>
</TR>

<! -- Files -->
$acum
</TD></TR></TABLE>";
}

sub html_top {
  my $o = shift;
  return ("
<TABLE WIDTH=100% CELLPADDING=0 CELLSPAING=0><TR>
<TD><FONT SIZE=+2 COLOR=#3a3a3a><B>".r->server->server_hostname." - file manager</B></FONT></TD>
<TD ALIGN=RIGHT VALIGN=TOP><A HREF=# onclick=\"window.display_help(); return false;\"><FONT COLOR=#3a3a3a>help</FONT></A></TD></TR></TABLE>
  ");
}

sub html_bottom {
  my $o = shift;
  return ("
<TABLE WIDTH=100% CELLPADDING=0 CELLSPAING=0><TR>
<TD ALIGN=RIGHT VALIGN=TOP><A HREF=http://www.cpan.org/modules/by-module/Apache/PMC TARGET=CPAN><FONT SIZE=-1 COLOR=BLACK>Apache-FileManager-$VERSION</FONT></A></FONT></TD>
</TR>
</TABLE>
  ");
}

































##############################################################################
# -------------- Utility Methods ------------------------------------------- #
##############################################################################

sub execute_cmds {
  my $o = shift;
  my $cmd = r->param('FILEMANAGER_cmd');
  my $arg = r->param('FILEMANAGER_arg');

  my $method = "cmd_$cmd";
  if ($o->can($method)) {
    $o->$method($arg);
  }
}

sub get_selected_files {
  my $o = shift;
  my @sel_files = r->param('FILEMANAGER_sel_files');
  return \ @sel_files;
}

#escape spaces in filename
sub filename_esc {
  my $o = shift;
  my $f = shift;
  $f =~ s/\ /\\\ /g;
  return $f;
}

sub formated_date {
  my $o = shift;
  my $date = shift;
  return strftime "%D", localtime($date);
}

sub get_clip_board {
  my $o = shift;

  #get copy and cut file arrays
  my $buffer_type = "";
  my $buffer_filenames = [];

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
        $buffer_type      = pop @ar;
        $buffer_filenames = \@ar;
      }
    }
  }
  return ($buffer_type, $buffer_filenames);
}
























###############################################################################
# -- Commands (called via form input from method execute_cmds or manually) -- #
###############################################################################
sub cmd_paste {
  my $o = shift;
  my $arg1 = shift;
  my ($buffer_type, $files) = $o->get_clip_board();

  my $count = 0;

  if ($buffer_type eq "copy") {
    my @files = map { $o->filename_esc($$o{DR}."/".$_) } @{ $files };
    $count = copy \1, @files, ".";
  } elsif ($buffer_type eq "cut") {
    for (@{ $files }) {
      my $file = $$o{DR}."/".$_;
      if (-d $file) {
        my $file = $o->filename_esc($file);
        my $tmp = copy \1, $file, ".";
        if ($tmp) {
          remove \1, $file and $count++;
        }
      } elsif (-f $file) {
        move($file, ".") and $count++;
      }
    }
  }

  if ($count == 0) {
    $$o{MESSAGE} = "0 files and directories pasted";
  } elsif ($count == 1) {
    $$o{MESSAGE} = "1 file or directory pasted";
  } else { 
    $$o{MESSAGE} = "$count files or directories pasted";
  }
  $$o{JS} = "window.setcookie(cookie_name,'',-1);";
  return undef;
}

sub cmd_delete {
  my $o = shift;
  my $arg1 = shift;
  my $sel_files = $o->get_selected_files();
  my @files = map { $o->filename_esc($$o{DR}."/".$_) } @{ $sel_files };
  my $count = remove \1, @files;
  if ($count == 0) {
    $$o{MESSAGE} = "0 files and directories deleted";
  } elsif ($count == 1) {
    $$o{MESSAGE} = "1 file or directory deleted";
  } else {
    $$o{MESSAGE} = "$count files or directories deleted";
  }
  return undef;
}


sub cmd_extract {
  my $o = shift;
  my $arg1 = shift;
  my $sel_files = $o->get_selected_files();
  foreach my $f (@{ $sel_files }) {
    my $esc = $o->filename_esc($$o{DR}."/".$f);
    my $archive = Archive::Any->new($esc);
    $archive->extract if defined $archive;
    $$o{MESSAGE} = "Files extracted.";
  }
  return undef;
}


sub cmd_upload {
  my $o = shift;
  my $arg1 = shift;
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

    my $arg = "> ".$$o{DR}."/".r->param('FILEMANAGER_curr_dir')."/".$filename;
    my $out_fh = Apache::File->new($arg);

    next if ! defined $out_fh;

    while (<$in_fh>) {
      print $out_fh $_;
    }
  }
  #$$o{MESSAGE} = "$count file(s) uploaded.";
  $$o{'view'} = "post_upload";
  return undef;
}

sub cmd_rename {
  my $o = shift;
  my $arg1 = shift;
  my $sel_files = $o->get_selected_files();
  my $file = $$o{DR}."/".$sel_files->[0];
  my $bool = move($file, $arg1);
  if ($bool) {
    $$o{MESSAGE} = "File renamed.";
  } else {
    $$o{MESSAGE} = "File could not be renamed.";
  }
  return undef;
}


sub cmd_rsync {
  my $o = shift;
  my $arg1 = shift;
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
  $$o{'view'} = "post_upload";
  return undef;
}


sub cmd_mkdir {
  my $o = shift;
  my $arg1 = shift;
  my $bool = mkdir $arg1;
  if ($bool) {
    $$o{MESSAGE} = "New directory added.";
  } else {
    $$o{MESSAGE} = "Could not make directory.";
  }
  return undef;
}





















1;
