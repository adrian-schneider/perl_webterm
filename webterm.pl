#!/usr/bin/perl
use strict;
use warnings;
use diagnostics;

use HTTP::Daemon;
use HTTP::Status;

my $writeHttpToWorker;
my $readHttpToWorker;

our $graphfilename  = "./.svggraph/graph.html";
our $statusfilename = "./.svggraph/status.txt";
our $statustempname = "./.svggraph/status.tmp";
our $screenwidth    = 1000;
our $screenheight   = 700;
our $paddingwidth   = 8;
our $paddingheight  = 8;
our $reloadinterval = 2000;

sub runHttpDaemon {
  my $port = shift;
  my $w = $screenwidth + 2*$paddingwidth;
  my $h = $screenheight + 2*$paddingheight;
  my $respbody = qq(<!DOCTYPE html>
<style>html,body{margin:0 0 0 0;overflow:hidden;background-color:black;color:white;font-family:consolas,monospace}</style>
<html><body>
HOLD<input id="hold" type="checkbox">
CMD: <input id="cmd" type="text" size="80" style="background-color:black;color:white;font-family:consolas,monospace;border:none;font-size:18px" onkeypress="transmit(event)">
<input id="status" type="text" size="80" style="background-color:black;color:white;font-family:consolas,monospace;border:none;font-size:18px" readonly>
<iframe id="graph" scrolling="no" width="$w" height="$h" frameBorder="0" src="graph" onload="iframeclick()">
</iframe>
<script>
function httpGetStatus() {
  var xmlHttp = new XMLHttpRequest();
  xmlHttp.onreadystatechange = function() {
    if (this.readyState == 4 && this.status == 200) {
      document.getElementById("status").value = this.responseText;
    }
  }
  xmlHttp.open("GET", "/status", true);
  xmlHttp.send();
}
function reload() {
  var graph = document.getElementById("graph");
  var graphSrc = graph.src;
  if (! document.getElementById("hold").checked) graph.src = graphSrc;
  httpGetStatus();
}
function iframeclick() {
  // Attaching a click event handler to the content of an iframe has to be
  // done after its content has been loaded.
  // This can be achieved using an onload handler.
  document.getElementById("graph").contentWindow.onclick = function(event){showCoords(event)};
}
function httpRequest(theUrl) {
  var xmlHttp = new XMLHttpRequest();
  xmlHttp.open("POST", theUrl, true);
  xmlHttp.send();
}
function showCoords(event) {
  var x = (event.pageX|0) - $paddingwidth;
  var y = (event.pageY|0) - $paddingheight;
  var f = (event.shiftKey?1:0) + (event.ctrlKey?2:0);
  httpRequest("/send?x=" + x + "&y=" + y + "&f=" + f);
}
function transmit(e) {
  // look for window.event in case event isn't passed in e = e || window.event;
  if (e.keyCode == 13) {
    var cmd = document.getElementById("cmd").value;
    document.getElementById("cmd").value = "";
    httpRequest("/send?cmd=" + cmd);
  }
}
setInterval(reload, $reloadinterval);
</script>
</body></html>);

  my $indexPage;
  $indexPage = HTTP::Response->new('200', 'Ok');
  $indexPage->header('Content-type' => 'text/html');
  $indexPage->header('Cache-control' => 'no-cache, no-store, must-revalidate');
  $indexPage->header('Content-length' => length($respbody));
  $indexPage->content($respbody);

  my $d = HTTP::Daemon->new(
    LocalPort => $port
    , ReuseAddr => 1
  ) 
    or die "Could not create http daemon: $!\n";
  print $writeHttpToWorker "hello=Please contact me at URL ", $d->url, "\n";
  while (my $c = $d->accept) {
    while (my $r = $c->get_request) {
      my $s = $r->uri->path;
      if ($r->method eq 'GET' or $r->method eq 'POST') {
        if (($s eq '/') || ($s eq '/index')) {
          $c->send_response($indexPage);
        }
        elsif ($s eq '/bye') {
          $c->send_response(RC_OK);
          print $writeHttpToWorker "bye\n";
          return;
        }
        elsif ($s eq '/send') {
          $c->send_response(RC_OK);
          print $writeHttpToWorker $r->uri->query, "\n";
        }
        elsif ($s eq '/graph') {
          $c->send_file_response($graphfilename);
        }
        elsif ($s eq '/status') {
          $c->send_file_response($statusfilename);
        }
        else {
          print $writeHttpToWorker "forbidden $s\n";
          $c->send_error(RC_FORBIDDEN);
        }
      }
      else {
        print $writeHttpToWorker "forbidden $s\n";
        $c->send_error(RC_FORBIDDEN);
      }
    }
    $c->close;
    undef($c);
  }
}

sub forkHttpDaemon {
  my $port = shift;
  my $pid = fork;
  die "Could not fork HTTP daemon: $!\n" unless defined $pid;
  if ($pid == 0) {
    close $readHttpToWorker;
    runHttpDaemon($port);
    close $writeHttpToWorker;
    exit;
  }
}

use constant EVTNONE    =>  0;
use constant EVTCOMMAND =>  1;
use constant EVTCLICK   =>  2;
use constant EVTHELLO   =>  3;
use constant EVTBYE     => 99;
use constant FLGNONE    =>  0;
use constant FLGSHIFT   =>  1;
use constant FLGCTRL    =>  2;

sub asEvent {
  my $line = shift;
  my %event = (
    'type'    => EVTNONE
    , 'cmd'   => ''
    , 'x'     => 0
    , 'y'     => 0
    , 'flg'   => FLGNONE
    , 'src'   => $line
  );
  if ($line =~ /^x=(\d+)\&y=(\d+)\&f=(\d+)$/) {
    $event{type} = EVTCLICK;
    $event{x}    = $1;
    $event{y}    = $2;
    $event{flg}  = $3;
  }
  elsif ($line =~ /^cmd=\s*(.+)$/) {
    $event{type} = EVTCOMMAND;
    $event{cmd}  = $1;
  }
  elsif ($line =~ /^hello=(.+)$/) {
    $event{type} = EVTHELLO;
    $event{cmd}  = $1;
    print STDERR "$1\n";
  }
  elsif ($line =~ /^bye$/) {
    $event{type} = EVTBYE;
  }
  return \%event;
}

sub run {
  my ($handlerRef, $port) = @_;
  pipe($readHttpToWorker, $writeHttpToWorker) 
    or die "Could not crete pipe: $!\n";
  $writeHttpToWorker->autoflush(1);
  forkHttpDaemon($port);
  my $evt;
  do {
    chomp(my $line = <$readHttpToWorker>);
    $evt = asEvent($line);
    #TODO: $self->$handlerRef($evt);
    &$handlerRef($evt);
  } until ($evt->{type} == EVTBYE);
  wait;
  close $writeHttpToWorker;
  close $readHttpToWorker;
  print STDERR "bye\n";
}

sub setStatus {
  my $str = shift;
  open my $fh, ">", $statustempname
    or die "Could not open $statustempname for writing: $!\n";
  print $fh $str;
  close $fh;
  unlink $statusfilename;
  rename $statustempname, $statusfilename;
}

sub handler {
  my $event = shift;
  if ($event->{type} == EVTCLICK) {
    print "xy:", $event->{x}
    , ",", $event->{y}
    , " f:", $event->{flg}
    , "\n";
  }
  elsif ($event->{type} == EVTCOMMAND) {
    print "cmd:", $event->{cmd}
    , "\n";
    if ($event->{cmd} =~ /long/) {
      setStatus('BUSY');
      sleep 10;
      setStatus('READY');
    }
  }
  elsif ($event->{type} == EVTNONE) {
    print "cmd:", $event->{src}
    , "\n";
  }
}

setStatus('READY 0');
run(\&handler, 8080);

