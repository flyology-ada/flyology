use strict;
use warnings;

BEGIN {
    eval {
        require POSIX;
        POSIX->import();
        POSIX->can('setpgid') or die "setpgid is unavailable\n";
        POSIX->can('WNOHANG') or die "wait status support is unavailable\n";
        1;
    } or do {
        my $reason = $@ || 'unknown POSIX error';
        print STDERR
          "run-with-timeout.sh: Perl 5 with core POSIX support is required: "
          . $reason;
        exit 2;
    };
}

sub usage {
    print STDERR "usage: run-with-timeout.sh SECONDS COMMAND [ARG ...]\n";
    exit 2;
}

sub wait_for_pid {
    my ($pid) = @_;

    while (1) {
        my $waited = waitpid $pid, 0;
        return $? if $waited == $pid;
        next if $waited < 0 && $!{EINTR};
        die "run-with-timeout.sh: waitpid($pid) failed: $!\n";
    }
}

sub exit_status {
    my ($wait_status) = @_;

    return POSIX::WEXITSTATUS($wait_status)
      if POSIX::WIFEXITED($wait_status);
    return 128 + POSIX::WTERMSIG($wait_status)
      if POSIX::WIFSIGNALED($wait_status);
    return 1;
}

sub poll_command {
    my ($pid, $signals, $pending_signal_ref) = @_;
    my $old_signals = POSIX::SigSet->new();
    POSIX::sigprocmask(POSIX::SIG_BLOCK(), $signals, $old_signals)
      or die "run-with-timeout.sh: cannot block forwarded signals: $!\n";

    my $pending = POSIX::SigSet->new();
    POSIX::sigpending($pending)
      or die "run-with-timeout.sh: cannot inspect pending signals: $!\n";
    if (!$$pending_signal_ref) {
        $$pending_signal_ref = 1 if $pending->ismember(POSIX::SIGHUP());
        $$pending_signal_ref = 2 if $pending->ismember(POSIX::SIGINT());
        $$pending_signal_ref = 15 if $pending->ismember(POSIX::SIGTERM());
    }

    if ($$pending_signal_ref) {
        POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old_signals)
          or die "run-with-timeout.sh: cannot restore forwarded signals: $!\n";
        return ('signal');
    }

    my $waited = waitpid $pid, POSIX::WNOHANG();
    if ($waited == $pid) {
        # Keep signals blocked through watchdog reaping and exit. The child is
        # now reaped, so this point is the normal-completion linearization and
        # the former process-group id must no longer be signalled.
        return ('command', $?);
    }

    my $wait_error = $!;
    my $wait_interrupted = $!{EINTR};
    POSIX::sigprocmask(POSIX::SIG_SETMASK(), $old_signals)
      or die "run-with-timeout.sh: cannot restore forwarded signals: $!\n";
    die "run-with-timeout.sh: waitpid($pid) failed: $wait_error\n"
      if $waited < 0 && !$wait_interrupted;
    return ('running');
}

sub write_byte {
    my ($handle, $byte) = @_;
    return syswrite($handle, $byte) if defined fileno $handle;
    return;
}

sub stop_watchdog {
    my ($pid, $cancel) = @_;

    write_byte($cancel, 'C');
    close $cancel;
    wait_for_pid($pid);
}

sub terminate_group {
    my ($group) = @_;

    # The command establishes this group before the controller starts its
    # watchdog. Keep the unreaped group leader as an identity anchor until
    # after both signals, so the negative kill cannot reach a reused group id.
    kill 'TERM', -$group;
    select undef, undef, undef, 1.0;
    kill 'KILL', -$group;
}

sub shell_word {
    my ($word) = @_;
    return "''" if $word eq '';
    return $word if $word =~ m{\A[-+./:=_,A-Za-z0-9]+\z};
    $word =~ s/'/'\\''/g;
    return "'$word'";
}

sub find_program {
    my ($name) = @_;

    for my $directory (split /:/, ($ENV{PATH} // '')) {
        next if $directory eq '';
        my $candidate = "$directory/$name";
        return $candidate if -f $candidate && -x $candidate;
    }
    return;
}

@ARGV >= 2 or usage();
my $limit_text = shift @ARGV;
$limit_text =~ m{\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)\z}
  && $limit_text > 0
  or usage();
my $limit = 0 + $limit_text;
my @command = @ARGV;

my $pending_signal = 0;
my $forwarded_signals = POSIX::SigSet->new(
    POSIX::SIGHUP(), POSIX::SIGINT(), POSIX::SIGTERM());
$SIG{HUP} = sub { $pending_signal ||= 1 };
$SIG{INT} = sub { $pending_signal ||= 2 };
$SIG{TERM} = sub { $pending_signal ||= 15 };
$SIG{PIPE} = 'IGNORE';

pipe my $group_ready_read, my $group_ready_write
  or die "run-with-timeout.sh: pipe failed: $!\n";
my $child = fork;
defined $child or die "run-with-timeout.sh: fork failed: $!\n";

if ($child == 0) {
    close $group_ready_read;
    $SIG{HUP} = 'DEFAULT';
    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{PIPE} = 'DEFAULT';

    if (POSIX::setpgid(0, 0) != 0) {
        my $error = "setpgid failed: $!";
        syswrite $group_ready_write, "E$error\n";
        POSIX::_exit(126);
    }
    syswrite $group_ready_write, "R\n";
    close $group_ready_write;

    exec @command or do {
        print STDERR "run-with-timeout.sh: cannot execute $command[0]: $!\n";
        POSIX::_exit(127);
    };
}

close $group_ready_write;
my $group_message = '';
while ($group_message !~ /\n/) {
    my $count = sysread $group_ready_read, my $chunk, 256;
    if (!defined $count) {
        next if $!{EINTR};
        die "run-with-timeout.sh: group setup read failed: $!\n";
    }
    last if $count == 0;
    $group_message .= $chunk;
}
close $group_ready_read;

if ($group_message ne "R\n") {
    my $status = wait_for_pid($child);
    $group_message =~ s/\s+\z//;
    $group_message =~ s/\AE//;
    my $reason = $group_message || 'command exited during process-group setup';
    print STDERR "run-with-timeout.sh: $reason\n";
    exit exit_status($status);
}

pipe my $cancel_read, my $cancel_write
  or do {
      my $pipe_error = $!;
      terminate_group($child);
      wait_for_pid($child);
      die "run-with-timeout.sh: watchdog control pipe failed: $pipe_error\n";
  };
pipe my $timeout_read, my $timeout_write
  or do {
      my $pipe_error = $!;
      close $cancel_read;
      close $cancel_write;
      terminate_group($child);
      wait_for_pid($child);
      die "run-with-timeout.sh: watchdog notification pipe failed: "
        . "$pipe_error\n";
  };

my $watchdog = fork;
if (!defined $watchdog) {
    my $fork_error = $!;
    close $cancel_read;
    close $cancel_write;
    close $timeout_read;
    close $timeout_write;
    terminate_group($child);
    wait_for_pid($child);
    die "run-with-timeout.sh: watchdog fork failed: $fork_error\n";
}

if ($watchdog == 0) {
    close $cancel_write;
    close $timeout_read;
    $SIG{HUP} = 'DEFAULT';
    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $SIG{PIPE} = 'IGNORE';

    my $read_mask = '';
    vec($read_mask, fileno($cancel_read), 1) = 1;
    my $ready = select $read_mask, undef, undef, $limit;
    if ($ready > 0) {
        sysread $cancel_read, my $ignored, 1;
        POSIX::_exit(0);
    }
    if (defined $ready && $ready == 0) {
        write_byte($timeout_write, 'T');
        POSIX::_exit(0);
    }
    write_byte($timeout_write, 'E');
    POSIX::_exit(2);
}

close $cancel_read;
close $timeout_write;
my $command_wait_status;
my $event = '';

while (1) {
    my ($command_state, $observed_status) =
      poll_command($child, $forwarded_signals, \$pending_signal);
    if ($command_state eq 'signal') {
        $event = 'signal';
        last;
    }
    if ($command_state eq 'command') {
        $command_wait_status = $observed_status;
        $event = 'command';
        last;
    }

    my $read_mask = '';
    vec($read_mask, fileno($timeout_read), 1) = 1;
    my $ready = select $read_mask, undef, undef, 0.02;
    next if !defined $ready || $ready <= 0;

    my $count = sysread $timeout_read, my $notification, 1;
    next if !defined $count && $!{EINTR};
    die "run-with-timeout.sh: watchdog notification failed: $!\n"
      if !defined $count;
    die "run-with-timeout.sh: watchdog exited without a notification\n"
      if $count == 0;

    # Prefer a command that completed at the deadline over a timeout report.
    ($command_state, $observed_status) =
      poll_command($child, $forwarded_signals, \$pending_signal);
    if ($command_state eq 'signal') {
        $event = 'signal';
        last;
    }
    if ($command_state eq 'command') {
        $command_wait_status = $observed_status;
        $event = 'command';
        last;
    }
    if ($notification ne 'T') {
        $event = 'watchdog_error';
        last;
    }
    $event = 'timeout';
    last;
}

if ($event eq 'command') {
    stop_watchdog($watchdog, $cancel_write);
    close $timeout_read;
    exit exit_status($command_wait_status);
}

stop_watchdog($watchdog, $cancel_write);
close $timeout_read;

if ($event eq 'timeout') {
    my $display = join ' ', map { shell_word($_) } @command;
    print STDERR "timeout: $limit_text seconds elapsed for pid $child "
      . "(process group $child): $display\n";
    if ($^O eq 'darwin') {
        my $sample = find_program('sample');
        if (defined $sample) {
            if (open my $sample_output, '-|', $sample, "$child", '1', '1') {
                print STDERR $_ while <$sample_output>;
                close $sample_output;
            }
        }
    }
} elsif ($event eq 'watchdog_error') {
    print STDERR "run-with-timeout.sh: watchdog failed\n";
}

my $forwarded_signal = $pending_signal;
terminate_group($child);
$command_wait_status = wait_for_pid($child);

exit 128 + $forwarded_signal if $forwarded_signal;
exit 2 if $event eq 'watchdog_error';
exit 124;
