use Cro::Tools::Link::Editor;
use Cro::Tools::LinkTemplate;
use Cro::Tools::Runner;
use Cro::Tools::Template;
use Cro::Tools::TemplateLocator;
use File::Find;
use Terminal::ANSIColor;

proto MAIN(|) is export {*}

multi MAIN('web', Str $host-port = '10203',
           :$filter = *, :$trace = False, :@trace-filters) {
    use Cro::Tools::Web;
    my ($host, $port) = parse-host-port($host-port);
    my $runner = Cro::Tools::Runner.new(
        services => Cro::Tools::Services.new(base-path => $*CWD),
        :$filter, :$trace, :@trace-filters
    );
    my $service = web $host, $port, $runner;
    say "Cro web interface running at http://$host:$port/";
    stop-on-sigint($service);
}

multi MAIN('stub', Str $service-type, Str $id, Str $path, $options = '') {
    my %options = parse-options($options);
    my $option-links = %options.grep({ .key eq 'link' }).first.value;
    %options .= grep({ not .key eq 'link' });

    my ($generated-links, @links);
    if $option-links {
        my @services = find(dir => $*CWD, name => / \.cro\.yml$/);
        my @link-templates = get-available-templates(Cro::Tools::LinkTemplate);

        for @$option-links -> $link {
            my ($service, $endp) = $link.split(':');
            unless $service|$endp {
                conk "`$link` is incorrect link format; Use 'service:endpoint'.";
            }
            my $cro-file;
            for @services {
                my $file = Cro::Tools::CroFile.parse($_.IO.slurp);
                if $file.id eq $service && $file.endpoints.grep(*.id eq $endp) {
                    $cro-file = $file; last;
                }
            }
            unless $cro-file {
                conk "There is no connection point to service $service with endpoint {$endp}.";
            }
            my $endpoint = $cro-file.endpoints.grep(*.id eq $endp).first;
            my $gl-template = @link-templates.grep(*.protocol eq $endpoint.protocol)[0];
            unless $gl-template ~~ Cro::Tools::LinkTemplate {
                conk "There is no link template for protocol {$endpoint.protocol}.";
            }
            my $generated = $gl-template.generate($service,    $endpoint.id,
                                                  (host-env => $endpoint.host-env,
                                                   port-env => $endpoint.port-env));
            $generated-links.push: $generated;

            @links.push: Cro::Tools::CroFile::Link.new(
                :$service, endpoint => $endpoint.id,
                host-env => $endpoint.host-env,
                port-env => $endpoint.port-env
            );
        }
    }

    my @templates = get-available-templates(Cro::Tools::Template);
    my $found = @templates.first(*.id eq $service-type);
    if $found ~~ Cro::Tools::Template {
        say "Stubbing a {$found.name} '$id' in '$path'...\n";
        if %options {
            check-and-complete-template-options($found.options, %options);
        }
        else {
            %options = request-template-options($found.options);
        }
        if $found.get-option-errors(%options) -> @errors {
            conk "Sorry, a stub can not be generated with this configuration.\n" ~
                @errors.map({ "* $_\n" }).join;
        }
        try {
            my $where = $path.IO;
            mkdir $where;
            $found.generate($where, $id, $id, %options, $generated-links, @links);
            CATCH {
                default {
                    note "Oops, stub generation failed: {.message}\n";
                    note "Please report the following location to the template developer:";
                    note .backtrace.full.indent(2);
                    exit 1;
                }
            }
        }
    }
    else {
        if @templates {
            conk "Couldn't find template '$service-type'. Available templates:\n" ~
                @templates.map(*.id).join(", ");
        }
        else {
            conk "No templates available.";
        }
    }

    sub request-template-options(@template-options) {
        return {} unless @template-options;
        say "First, please provide a little more information.\n";
        my %got;
        for @template-options -> $opt {
            my $id = $opt.id;
            my $default = $opt.default ~~ Callable
                ?? $opt.default().(%got)
                !! $opt.default;
            print $opt.name;
            given $opt.type {
                when Bool {
                    loop {
                        my $proposed = do with $default {
                            my $default-value = $default ?? 'yes' !! 'no';
                            prompt(" (yes/no) [$default-value]: ") || $default-value;
                        }
                        else {
                            prompt(" (yes/no): ");
                        }
                        if $proposed ~~ /:i ^ y/ {
                            %got{$id} = True;
                            last;
                        }
                        elsif $proposed ~~ /:i ^ n/ {
                            %got{$id} = False;
                            last;
                        }
                        else {
                            print "Sorry, expected yes or no.\n$opt.name()";
                        }
                    }
                }
                when Int {
                    loop {
                        my $proposed = +do with $default {
                            prompt(" [$default]: ") || $default;
                        }
                        else {
                            prompt(": ");
                        }
                        if $proposed ~~ $opt.type {
                            %got{$id} = $proposed;
                            last;
                        }
                        else {
                            print "Sorry, that isn't a valid {.^name}.\n$opt.name()";
                        }
                    }
                }
                when Str {
                    loop {
                        my $proposed = do with $default {
                            prompt(" [$default]: ") || $default;
                        }
                        else {
                            prompt(": ");
                        }
                        if $proposed ~~ $opt.type {
                            %got{$id} = $proposed;
                            last;
                        }
                        else {
                            print "Sorry, that isn't a valid {.^name}.\n$opt.name()";
                        }
                    }
                }
                default {
                    conk "Sorry, don't know how to handle {.^name} options.";
                }
            }
        }
        return %got;
    }

    sub check-and-complete-template-options(@template-options, %provided) {
        for @template-options -> $opt {
            without %provided{$opt.id} {
                with $opt.default -> $def {
                    %provided{$opt.id} = $def ~~ Callable ?? $def(%provided) !! $def;
                }
                else {
                    conk "Sorry, this template requires the option '$opt.id()'.";
                }
            }
            unless %provided{$opt.id} ~~ $opt.type {
                conk "Sorry, '%provided{$opt.id}' is not a valid $opt.type().^name().";
            }
        }
        if %provided > @template-options {
            my @unrec = keys %provided.keys (-) @template-options>>.id;
            conk @unrec == 1
                ?? "Unrecognized option '@unrec[0]'."
                !! "Unrecognized options: @unrec.map({ "'$_'" }).join(", ").";
        }
    }
}

multi MAIN('services') {
    my @services = find(dir => $*CWD, name => / \.cro\.yml$/);
    for @services -> $path {
        my $cro-file = Cro::Tools::CroFile.parse($path.IO.slurp);
        with $cro-file {
            say colored("{.id} ({.name})", "bold"), RESET();
            say $path.relative($*CWD);
            for .endpoints {
                say "🔌 Endpoint {.id} ({.name})";
                say "  Host environment variable: {.host-env}";
                say "  Port environment variable: {.port-env}";
            }
        }
        say '';
    }
}

multi MAIN('link', 'add', $from-service-id, $to-service-id, $to-endpoint-id?) {
    add-link($from-service-id, $to-service-id, $to-endpoint-id);
}
multi MAIN('link', 'show', $service-id?) {
    show-link($service-id);
}
multi MAIN('link', 'code', $from-service-id, $to-service-id, $to-endpoint-id?) {
    code-link($from-service-id, $to-service-id, $to-endpoint-id);
}
multi MAIN('link', 'rm', $from-service-id, $to-service-id, $to-endpoint-id?) {
    rm-link($from-service-id, $to-service-id, $to-endpoint-id);
}

multi MAIN('run') {
    run-services();
}

multi MAIN('run', *@service-name) {
    run-services(filter => any(@service-name));
}

multi MAIN('trace', *@service-name-or-filter) {
    my @service-name;
    my @trace-filters;
    for @service-name-or-filter {
        if .starts-with(':') {
            push @trace-filters, .lc;
        }
        else {
            push @service-name, $_;
        }
    }
    run-services
        filter => @service-name ?? any(@service-name) !! *,
        :trace, :@trace-filters;
}

sub run-services(:$filter = *, :$trace = False, :@trace-filters) {
    my $runner = Cro::Tools::Runner.new(
        services => Cro::Tools::Services.new(base-path => $*CWD),
        :$filter, :$trace, :@trace-filters
    );
    react {
        my %service-id-colors;

        whenever $runner.run() {
            when Cro::Tools::Runner::UnableToStart {
                my $color = %service-id-colors{.service-id} = next-color();
                note color($color), "\c[WARNING SIGN] {.service-id} cannot be started", RESET();
            }
            when Cro::Tools::Runner::Started {
                my $color = %service-id-colors{.service-id} = next-color();
                say colored
                    "\c[BLACK RIGHT-POINTING TRIANGLE] Starting {.cro-file.name} ({.service-id})",
                    "bold $color";
                my %endpoint-ports = .endpoint-ports;
                for .cro-file.endpoints -> $endpoint {
                    my $port = %endpoint-ports{$endpoint.id};
                    print color($color) ~ "\c[ELECTRIC PLUG] Endpoint $endpoint.name() will be ";
                    given $endpoint.protocol {
                        when 'http' {
                            say "at http://localhost:$port/" ~ RESET();
                        }
                        when 'https' {
                            say "at https://localhost:$port/" ~ RESET();
                        }
                        default {
                            say "on port $port" ~ RESET();
                        }
                    }
                }
            }
            when Cro::Tools::Runner::Restarted {
                my $color = %service-id-colors{.service-id};
                say colored
                    "\c[BLACK UNIVERSAL RECYCLING SYMBOL] Restarting {.cro-file.name} ({.service-id})",
                    "bold $color";
            }
            when Cro::Tools::Runner::Output {
                my $color = %service-id-colors{.service-id};
                if .on-stderr {
                    note color($color), "\c[WARNING SIGN] {.service-id} ", RESET(),
                        .line;
                }
                else {
                    say color($color), "\c[NOTEBOOK] {.service-id} ", RESET(),
                        .line;
                }
            }
            when Cro::Tools::Runner::Trace {
                my $color = %service-id-colors{.service-id};
                my $prefix = "\c[EYEGLASSES] {.service-id} ";
                my $event = do given .event {
                    when 'EMIT' { "\c[HIGH VOLTAGE SIGN] EMIT" }
                    when 'DONE' { "\c[BLACK SQUARE FOR STOP] DONE" }
                    when 'QUIT' { "\c[SKULL AND CROSSBONES] QUIT" }
                    default { "? {.uc}" }
                }
                note colored($prefix, $color) ~ colored($event, "bold") ~
                    " [{.id}] {.component}";
                with .data -> $data {
                    note $data.trim.indent($prefix.chars + 2);
                }
            }
        }

        whenever signal(SIGINT) {
            say "Shutting down...";
            done;
        }

        sub next-color() {
            shift state @colors ||= <green yellow blue red cyan magenta>;
        }
    }
}

multi MAIN('serve', Str $host-port, Str $directory = '.') {
    my ($host, $port) = parse-host-port($host-port);
    if $directory.IO.d {
        use Cro::Tools::Serve;
        my $service = serve $host, $port, $directory;
        say "Serving '$directory' at http://$host:$port/";
        stop-on-sigint($service);
    }
    else {
        conk "The serve command requires a directory, but '$directory' isn't one.";
    }
}

sub parse-host-port($host-port) {
    my ($host, $port);
    given $host-port {
        when /^(\d+)$/ {
            $host = 'localhost';
            $port = +$host-port;
        }
        when /^ (.+) ':' (\d+) $/ {
            $host = ~$0;
            $port = +$1;
        }
        default {
            conk "Don't understand '$host-port'; expected port number of host:port.";
        }
    }
    unless 1 <= $port <= 0xFFFF {
        conk "Port number $port is out of range.";
    }
    return $host, $port;
}

sub parse-options($options) {
    my grammar Options {
        token TOP { <option>* % [\s*] }
        token option {
            [
            || ':'
                [
                | $<neg>='!' <key=.ident>
                | <key=.ident> [ '<' $<value>=[<-[>]>*] '>' ]?
                || { conk "Malformed option at '$/.orig.substr($/.pos)'." }
                ]
            || <!before $> { conk "Expected option starting with : at '$/.orig.substr($/.pos)'." }
            ]
        }
    }
    with Options.parse($options) {
        my %opts;
        my @links;
        for $<option> -> $/ {
            if ~$<key> eq 'link' {
                @links .= append(~$<value>);
            } else {
                %opts{~$<key>} =
                  $<neg>    ?? False     !!
                  $<value>  ?? ~$<value> !!
                               True
            }
        }
        %opts<link> = @links;
        return %opts;
    }
    else {
        conk "Could not parse options.";
    }
}

sub stop-on-sigint($service) {
    react {
        my $sigints = 0;
        whenever signal(SIGINT) {
            if $sigints++ {
                done;
            }
            else
            {
                say "Shutting down server cleanly (Ctrl+C again to force exit).";
                whenever start $service.stop {
                    done;
                }
            }
        }
    }
}

sub conk($message) {
    note $message;
    exit 1;
}
