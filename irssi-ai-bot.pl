use strict;
use Irssi;
use Irssi::Irc;
use LWP::UserAgent;
use HTTP::Request::Common;
use JSON;
use IO::Handle;
use utf8;
use POSIX ":sys_wait_h";
use File::Spec;

our $VERSION = '3.7';
our %IRSSI = (
    authors     => 'DrScarab',
    contact     => '93016425+DrScarab@users.noreply.github.com',
    name        => 'irssi_ai_bot',
    description => 'Irssi AI bot with multiple personalities from a JSON config (non-blocking)',
    license     => 'MIT',
);

# ==================== CONFIGURATION ====================
# Path to config file (defaults to ~/.irssi/scripts/irssi-ai-bot.config.json)
my $CONFIG_FILE = Irssi::get_irssi_dir() . "/scripts/irssi-ai-bot.config.json";

my $RATE_LIMIT_SEC = 3;
my $FIRST_DELAY_SEC = 90;
my $SECOND_DELAY_SEC = 90;
my $FINAL_DELAY_SEC = 60;
my $API_TIMEOUT_SEC = 240;

# ======================================================

my %last_response_time;

# Per-channel, per-bot history: $history{$channel}{$bot_name} = [ ... ]
my %history;

my @bots;
my %pending_requests;

sub load_history_from_file {
    my ($bot_name) = @_;
    (my $history_file = $CONFIG_FILE) =~ s|[^/]+$|${bot_name}_history.json|;
    if (-e $history_file) {
        my $json_text;
        if (open(my $fh, '<', $history_file)) {
            local $/;
            $json_text = <$fh>;
            close($fh);
            my $data = eval { decode_json($json_text) };
            if (!$@ && ref($data) eq 'HASH') {
                for my $channel (keys %$data) {
                    $history{$channel}{$bot_name} = $data->{$channel};
                }
                Irssi::print("%G>>%n irssi_ai_bot: Loaded history for '$bot_name' from $history_file");
            }
        }
    }
}

sub save_history_to_file {
    my ($bot_name) = @_;
    (my $history_file = $CONFIG_FILE) =~ s|[^/]+$|${bot_name}_history.json|;
    my %bot_history;
    for my $channel (keys %history) {
        if (exists $history{$channel}{$bot_name}) {
            $bot_history{$channel} = $history{$channel}{$bot_name};
        }
    }
    if (open(my $fh, '>', $history_file)) {
        print $fh encode_json(\%bot_history);
        close($fh);
    }
}

# Load bot configurations from JSON file
sub load_bots {
    @bots = ();

    if (!-e $CONFIG_FILE) {
        Irssi::print("%R>>%n irssi_ai_bot: Config file not found at $CONFIG_FILE");
        Irssi::print("%R>>%n irssi_ai_bot: Please create a config file based on the example.");
        return;
    }

    my $json_text;
    open(my $fh, '<', $CONFIG_FILE) or do {
        Irssi::print("%R>>%n irssi_ai_bot: Failed to open config file: $!");
        return;
    };
    {
        local $/;
        $json_text = <$fh>;
    }
    close($fh);

    my $data = eval { decode_json($json_text) };
    if ($@) {
        Irssi::print("%R>>%n irssi_ai_bot: JSON Error in config: $@");
        return;
    }

    if (ref($data) eq 'ARRAY') {
        my @active_bots;
        foreach my $bot (@$data) {
            next unless defined $bot->{enabled} ? $bot->{enabled} : 1;
            push @active_bots, $bot;
        }
        @bots = @active_bots;
        Irssi::print("%G>>%n irssi_ai_bot: Loaded " . scalar(@bots) . " bot personalities.");
        foreach my $bot (@bots) {
            Irssi::print("%G>>%n   - Bot '$bot->{name}' using model '$bot->{model}'");
            load_history_from_file($bot->{name});
        }
    } else {
        Irssi::print("%R>>%n irssi_ai_bot: Invalid config format. Expected an array of bots.");
    }
}

sub handle_public {
    my ($server, $msg, $nick, $address, $target) = @_;

    if ($msg =~ /^!aibotctrl\s+(\S+)(?:\s+(.*))?$/i) {
        my $cmd = $1;
        my $_args = $2 // '';

        if ($cmd eq 'confreload') {
            load_bots();
            if (@bots > 0) {
                $server->command("MSG $target Config reloaded successfully.");
            } else {
                $server->command("MSG $target No bots loaded.");
            }
            return;
        }
    }

    # Find which bot is being addressed
    my $matched_bot;
    my $user_msg = $msg;

    foreach my $bot (@bots) {
        my $name = $bot->{name};
        # Check if message starts with bot name followed by delimiter
        if ($msg =~ /^(?:\Q$name\E[\s,:;.!?]+|\b\Q$name\E[\s,:;.!?]+)/i) {
            $matched_bot = $bot;
            $user_msg =~ s/^(?:\Q$name\E[\s,:;.!?]+|\b\Q$name\E[\s,:;.!?]+)//i;
            last;
        }
    }

    # If no bot was addressed, return
    return unless $matched_bot;

    my $bot_name = $matched_bot->{name};

    $user_msg =~ s/^\s+|\s+$//g;
    return if $user_msg eq '';

    # Rate limiting (per-bot)
    my $now = time();
    if (exists $last_response_time{$bot_name} &&
        $now - $last_response_time{$bot_name} < $RATE_LIMIT_SEC) {
        return;
    }
    $last_response_time{$bot_name} = $now;

    my $max_history = $matched_bot->{max_history} // 20; # Default to 20 if not set

    # Build messages array: system + history for this channel/bot + current user message
    my @messages = ({ role => 'system', content => $matched_bot->{system_prompt} });

    if (exists $history{$target}{$bot_name}) {
        my @chan_hist = @{$history{$target}{$bot_name}};
        my $start = @chan_hist > $max_history * 2 ? -($max_history * 2) : 0;
        push @messages, @chan_hist[$start .. $#chan_hist];
    }

    push @messages, { role => 'user', content => "$nick says: $user_msg" };

    my %api_params = (
        model       => $matched_bot->{model},
        messages    => \@messages,
        max_tokens  => $matched_bot->{max_tokens},
        temperature => $matched_bot->{temperature},
    );
    $api_params{tools} = $matched_bot->{tools} if exists $matched_bot->{tools};
    my $json = encode_json(\%api_params);

    # Create a pipe for child-to-parent communication using native pipe()
    my ($reader, $writer);
    if (!pipe($reader, $writer)) {
        Irssi::print("%R>>%n irssi_ai_bot: Failed to create pipe: $!");
        return;
    }

    # Set reader to non-blocking immediately to prevent freezing Irssi
    $reader->blocking(0);

    my $pid = fork();

    if (!defined $pid) {
        Irssi::print("%R>>%n irssi_ai_bot: Fork failed");
        close($reader);
        close($writer);
        return;
    }

    if ($pid == 0) {
        # CHILD PROCESS
        close($reader); # Child doesn't need reader

        # IMPORTANT: Detach from Irssi's terminal to prevent input blocking
        close(STDIN);
        close(STDOUT);
        close(STDERR);

        my $ua = LWP::UserAgent->new(timeout => 240);
        $ua->agent('Irssi-ai-bot/3.7');

        my $endpoint = $matched_bot->{endpoint} // 'https://openrouter.ai/api/v1/chat/completions';

        my $req = POST $endpoint,
            'Authorization' => "Bearer $matched_bot->{api_key}",
            'Content-Type'  => 'application/json',
            'HTTP-Referer'  => 'http://localhost/irssi-ai-bot',
            'X-Title'       => 'irssi-ai-bot',
            Content         => $json;

        my $res = $ua->request($req);
        my $result;

        if ($res->is_success) {
            $result = $res->decoded_content;
        } else {
            $result = encode_json({ error => $res->status_line, http_status => $res->code });
        }

        # Write result to parent
        print $writer $result . "\n";
        close($writer);
        exit(0);
    }

    # PARENT PROCESS
    close($writer); # Parent doesn't need writer

    # Store context for the callback
    my $request_id = "$target:$nick:" . time();
    
    # Add input handler and store the tag
    my $input_tag = Irssi::input_add(fileno($reader), INPUT_READ, \&handle_api_response, $request_id);

    $pending_requests{$request_id} = {
        server      => $server,
        target      => $target,
        nick        => $nick,
        user_msg    => $user_msg,
        pipe        => $reader,
        buffer      => '',
        bot_name    => $bot_name,
        tag         => $input_tag,
        stage       => 0,
        messages    => \@messages,
        bot_config  => $matched_bot,
        timer_tag   => undef,
    };

    Irssi::timeout_add($FIRST_DELAY_SEC * 1000, \&check_request_timeout, $request_id);

}

sub handle_api_response {
    my ($request_id) = @_;

    return unless exists $pending_requests{$request_id};

    my $req_info = $pending_requests{$request_id};
    my $fh = $req_info->{pipe};

    # Read available data
    my $chunk;
    my $bytes_read = sysread($fh, $chunk, 65536);

    if (!defined $bytes_read) {
        # If error is "Resource temporarily unavailable", just wait for next signal
        if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
            return;
        }
        # Otherwise treat as closed/error
        $bytes_read = 0;
    }

    if ($bytes_read == 0) {
        if (defined $req_info->{timer_tag}) {
            Irssi::timeout_remove($req_info->{timer_tag});
            $req_info->{timer_tag} = undef;
        }

        if (defined $req_info->{tag}) {
            Irssi::input_remove($req_info->{tag});
        }
        close($fh);

        my $response_json = $req_info->{buffer};
        my $server = $req_info->{server};
        my $target = $req_info->{target};
        my $nick = $req_info->{nick};
        my $user_msg = $req_info->{user_msg};
        my $bot_name = $req_info->{bot_name};
        my $messages = $req_info->{messages};
        my $bot_config = $req_info->{bot_config};

        delete $pending_requests{$request_id};

        Irssi::print("%R>>%n irssi_ai_bot RAW: $response_json");

        my $reply = undef;
        my $hard_error = 0;

        if ($response_json ne '') {
            my $data = eval { decode_json($response_json) };
            if (!$@ && $data->{error}) {
                my $http_status = $data->{http_status} // 0;
                if ($http_status >= 400 && $http_status < 500 && $http_status != 429 && $http_status != 408) {
                    $hard_error = 1;
                } elsif ($http_status >= 500) {
                    $hard_error = 0;
                } else {
                    $hard_error = 1;
                }
            } elsif (!$@ && !$data->{error} && $data->{choices} && @{$data->{choices}}) {
                $reply = $data->{choices}[0]{message}{content};
                $reply =~ s/^\s+|\s+$//g;
                $reply = undef if $reply eq '';
            }
        } else {
            $hard_error = 0;
        }

        if (defined $reply) {
            utf8::upgrade($reply);
            $server->command("MSG $target $reply");

            push @{$history{$target}{$bot_name}}, { role => 'user', content => "$nick says: $user_msg" };
            push @{$history{$target}{$bot_name}}, { role => 'assistant', content => $reply };

            save_history_to_file($bot_name);
        } elsif ($hard_error) {
            $server->command("MSG $target I'm temporarily unavailable, try again later.");
        } else {
            $pending_requests{$request_id} = {
                server      => $server,
                target      => $target,
                nick        => $nick,
                user_msg    => $user_msg,
                bot_name    => $bot_name,
                stage       => 0,
                messages    => $messages,
                bot_config  => $bot_config,
                timer_tag   => Irssi::timeout_add($FIRST_DELAY_SEC * 1000, \&check_request_timeout, $request_id),
            };
        }
    } else {
        # More data available, append to buffer
        $req_info->{buffer} .= $chunk;
    }
}

sub check_request_timeout {
    my ($request_id) = @_;

    return unless exists $pending_requests{$request_id};

    my $req_info = $pending_requests{$request_id};
    my $server = $req_info->{server};
    my $target = $req_info->{target};
    my $stage = $req_info->{stage};

    if ($stage == 0) {
        $server->command("MSG $target Still thinking...");
        $req_info->{stage} = 1;
        $req_info->{timer_tag} = Irssi::timeout_add($SECOND_DELAY_SEC * 1000, \&check_request_timeout, $request_id);
        retry_api_request($request_id);
    } elsif ($stage == 1) {
        $server->command("MSG $target Still thinking...");
        $req_info->{stage} = 2;
        $req_info->{timer_tag} = Irssi::timeout_add($FINAL_DELAY_SEC * 1000, \&check_request_timeout, $request_id);
        retry_api_request($request_id);
    } elsif ($stage == 2) {
        $server->command("MSG $target I couldn't come up with an answer.");
        cleanup_request($request_id);
    }
}

sub retry_api_request {
    my ($request_id) = @_;

    return unless exists $pending_requests{$request_id};

    my $req_info = $pending_requests{$request_id};

    if (defined $req_info->{tag}) {
        Irssi::input_remove($req_info->{tag});
    }
    if (defined $req_info->{pipe}) {
        close($req_info->{pipe});
    }

    my $messages = $req_info->{messages};
    my $bot_config = $req_info->{bot_config};

    my %retry_params = (
        model       => $bot_config->{model},
        messages    => $messages,
        max_tokens  => $bot_config->{max_tokens},
        temperature => $bot_config->{temperature},
    );
    $retry_params{tools} = $bot_config->{tools} if exists $bot_config->{tools};
    my $json = encode_json(\%retry_params);

    my ($reader, $writer);
    if (!pipe($reader, $writer)) {
        Irssi::print("%R>>%n irssi_ai_bot: Retry pipe failed: $!");
        return;
    }
    $reader->blocking(0);

    my $pid = fork();

    if (!defined $pid) {
        Irssi::print("%R>>%n irssi_ai_bot: Retry fork failed");
        close($reader);
        close($writer);
        return;
    }

    if ($pid == 0) {
        close($reader);
        close(STDIN);
        close(STDOUT);
        close(STDERR);

        my $ua = LWP::UserAgent->new(timeout => $API_TIMEOUT_SEC);
        $ua->agent('Irssi-ai-bot/3.7');

        my $endpoint = $bot_config->{endpoint} // 'https://openrouter.ai/api/v1/chat/completions';

        my $req = POST $endpoint,
            'Authorization' => "Bearer $bot_config->{api_key}",
            'Content-Type'  => 'application/json',
            'HTTP-Referer'  => 'http://localhost/irssi-ai-bot',
            'X-Title'       => 'irssi-ai-bot',
            Content         => $json;

        my $res = $ua->request($req);
        my $result = $res->is_success ? $res->decoded_content : encode_json({ error => $res->status_line, http_status => $res->code });

        print $writer $result . "\n";
        close($writer);
        exit(0);
    }

    close($writer);

    my $input_tag = Irssi::input_add(fileno($reader), INPUT_READ, \&handle_api_response, $request_id);

    $req_info->{pipe} = $reader;
    $req_info->{tag} = $input_tag;
    $req_info->{buffer} = '';
}

sub cleanup_request {
    my ($request_id) = @_;

    if (exists $pending_requests{$request_id}) {
        my $req_info = $pending_requests{$request_id};
        if (defined $req_info->{tag}) {
            Irssi::input_remove($req_info->{tag});
        }
        if (defined $req_info->{pipe}) {
            close($req_info->{pipe});
        }
        if (defined $req_info->{timer_tag}) {
            Irssi::timeout_remove($req_info->{timer_tag});
        }
        delete $pending_requests{$request_id};
    }
}

sub periodic_reap {
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {}
}

sub reap_children {
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {}
}

# Clean up on unload
sub UNLOAD {
    reap_children();
    for my $request_id (keys %pending_requests) {
        if (defined $pending_requests{$request_id}{tag}) {
             Irssi::input_remove($pending_requests{$request_id}{tag});
        }
        close($pending_requests{$request_id}{pipe});
    }
    %pending_requests = ();
}

# Set up SIGCHLD handler to reap zombies
$SIG{CHLD} = \&reap_children;

# Load bots on start
load_bots();

Irssi::signal_add('message public', 'handle_public');

Irssi::timeout_add(30000, \&periodic_reap, undef);

Irssi::print("%G>>%n irssi_ai_bot v3.7 loaded - Multi-character support (!aibotctrl confreload).");
