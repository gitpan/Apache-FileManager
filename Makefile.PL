use ExtUtils::MakeMaker;
WriteMakefile(
    'AUTHOR'      => 'Philip Collins (collins_p@yahoo.com)',
    'NAME'		=> 'Apache::FileManager',
    'VERSION_FROM'	=> 'FileManager.pm',
    'PREREQ_PM'		=> { 
      'Apache::Request' => 0,
      'File::NCopy'     => 0,
      'File::Copy'      => 0,
      'File::Remove'    => 0,
      'File::stat'      => 0,
      'Archive::Any'    => 0,
      'POSIX'           => 0,
      'CGI::Cookie'     => 0
    }
);

