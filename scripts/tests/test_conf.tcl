# Runs the rendered eggdrop.conf in a child interpreter with Eggdrop's commands
# stubbed, and checks the slot, rotation, claim, jump and log-bind logic.
# Usage: tclsh test_conf.tcl DIR   (DIR holds <name>.conf; cwd is DIR)

set dir [lindex $argv 0]
set failures 0

proc check {name want got} {
  global failures
  if {$want ne $got} {
    puts stderr "FAIL: $name: expected '$want', got '$got'"
    incr failures
  }
}

# A bot with the given conf. slot is the content of slot.tcl, or empty for none.
# state is a dict: botnick, serveraddress, online, peers (opped nicks),
# present (nicks on the channel), joined (is the bot in the channel).
proc boot {conf slot {state {}}} {
  global dir
  file delete -force slot.tcl
  if {$slot ne ""} {
    set fd [open slot.tcl w]
    puts $fd $slot
    close $fd
  }
  set i [interp create]
  $i eval {
    set server_adds {}
    set calls {}
    set binds {}
    proc loadmodule {args} {}
    proc logfile {args} {}
    proc server {cmd args} {lappend ::server_adds [join $args " "]}
    proc bind {type flags mask proc} {lappend ::binds [list $type $mask $proc]}
    proc putquick {args} {}
    proc putlog {args} {}
    proc utimer {args} {return t1}
    proc killutimer {args} {}
    proc unixtime {} {return $::now}
    proc channels {} {return {#c}}
    proc botonchan {chan} {return $::joined}
    proc onchan {nick chan} {expr {[lsearch -exact -nocase $::present $nick] >= 0}}
    proc isop {nick chan} {expr {[lsearch -exact -nocase $::peers $nick] >= 0}}
    proc isbotnick {nick} {string equal -nocase $nick $::botnick}
    proc jump {args} {lappend ::calls [list jump {*}$args]}
    proc exec {args} {lappend ::calls [list exec {*}$args]; return ""}
    proc eggdrop_up {} {expr {${::server-online} > 0}}
    rename source real_source
    proc source {path} {
      if {$path eq "scripts/eggdrop.tcl"} {return}
      uplevel 1 [list real_source $path]
    }
    set ::env(EGGDROP_INSTANCE_ID) i-0123456789abcdef0
    set ::serveraddress ""
    set ::server ""
    set ::now 100000
    set ::peers {}
    set ::present {}
    set ::joined 1
    set ::server-online 0
    set ::eggdrop_region us-west-2
  }
  dict set defaults online 0
  foreach {key value} [dict merge $defaults $state] {
    switch -- $key {
      botnick {$i eval [list set ::botnick $value]}
      serveraddress {$i eval [list set ::serveraddress $value]}
      online {$i eval [list set ::server-online $value]}
      peers {$i eval [list set ::peers $value]}
      present {$i eval [list set ::present $value]}
      joined {$i eval [list set ::joined $value]}
    }
  }
  set fd [open [file join $dir $conf.conf]]
  set text [read $fd]
  close $fd
  $i eval $text
  return $i
}

proc servers {i} {$i eval {set server_adds}}
proc calls {i} {$i eval {set calls}}

# No slot file: today's boot.
set i [boot two_by_three ""]
check "no slot: nick" naju [$i eval {set nick}]
check "no slot: altnick" naju? [$i eval {set altnick}]
check "no slot: servers in listed order" \
  {{a.example.net +6697} {b.example.net +7000} {c.example.net +6697}} [servers $i]

# Slot 1 of 2 nicks over 3 servers: the nick and the first server follow the
# slot, the rest stay as failover in rotated order.
set i [boot two_by_three "set eggdrop_boot_slot 1"]
check "slot 1: nick" zera [$i eval {set nick}]
check "slot 1: ident" zera [$i eval {set username}]
check "slot 1: realname" zera [$i eval {set realname}]
check "slot 1: altnick keeps the first nick" naju? [$i eval {set altnick}]
check "slot 1: servers rotated" \
  {{b.example.net +7000} {c.example.net +6697} {a.example.net +6697}} [servers $i]
check "slot 1: canonical list unchanged" \
  {{a.example.net +6697} {b.example.net +7000} {c.example.net +6697}} [list {*}[$i eval {set eggdrop_servers}]]

set i [boot two_by_three "set eggdrop_boot_slot 0"]
check "slot 0: nick" naju [$i eval {set nick}]
check "slot 0: servers" \
  {{a.example.net +6697} {b.example.net +7000} {c.example.net +6697}} [servers $i]

# Three nicks over two servers: the index wraps.
set i [boot three_by_two "set eggdrop_boot_slot 2"]
check "slot 2 of 3: nick" kali [$i eval {set nick}]
check "slot 2 of 3: servers wrap to the first" \
  {{a.example.net +6697} {b.example.net +7000}} [servers $i]
set i [boot three_by_two "set eggdrop_boot_slot 1"]
check "slot 1 of 3 on 2 servers" \
  {{b.example.net +7000} {a.example.net +6697}} [servers $i]

# The first server entry is the slot server, so a bot that boots there never jumps.
set i [boot two_by_three "set eggdrop_boot_slot 1" {botnick zera serveraddress b.example.net:+7000}]
check "slot boot: on its slot server" 1 [$i eval {eggdrop_on_slot_server}]
check "slot boot: slot server is the first added" [lindex [servers $i] 0] [join [$i eval {eggdrop_slot_server}] " "]

# A spare whose retiring peer holds slot 1 takes that server but keeps the
# default nick, and claims the nick when it frees.
set i [boot two_by_three "set eggdrop_boot_server 1"]
check "spare: nick stays the first" naju [$i eval {set nick}]
check "spare: servers rotated to the retiring peer's" \
  {{b.example.net +7000} {c.example.net +6697} {a.example.net +6697}} [servers $i]
set i [boot two_by_three "set eggdrop_boot_server 2"]
check "spare: index past the nicks is ignored" \
  {{a.example.net +6697} {b.example.net +7000} {c.example.net +6697}} [servers $i]
set i [boot two_by_three "set eggdrop_boot_server 1" {botnick naju? online 99000 serveraddress b.example.net:+7000 present {zera}}]
$i eval {eggdrop_claim_nick 0 0 0 0 0}
check "spare: claims the nick that frees" naju [$i eval {set ::nick}]

# A bad slot file is ignored.
foreach {label content} [list \
  not-a-number "set eggdrop_boot_slot x" \
  out-of-range "set eggdrop_boot_slot 2" \
  negative "set eggdrop_boot_slot -3" \
  syntax-error "set eggdrop_boot_slot \{" \
  other-command "exit 3" \
  trailing-code "set eggdrop_boot_slot 1; exit 3"] {
  set i [boot two_by_three $content]
  check "bad slot ($label): nick" naju [$i eval {set nick}]
  check "bad slot ($label): servers" \
    {{a.example.net +6697} {b.example.net +7000} {c.example.net +6697}} [servers $i]
}

# A rehash keeps a claimed name.
set i [boot two_by_three "set eggdrop_boot_slot 0" {botnick zera}]
check "rehash keeps the claimed nick" zera [$i eval {set nick}]

# Claiming: a bot that holds no listed name takes the first no one wears.
set i [boot two_by_three "" {botnick naju? online 1 present {naju}}]
$i eval {eggdrop_claim_nick 0 0 0 0 0}
check "claim: first free name" zera [$i eval {set ::nick}]
set i [boot two_by_three "" {botnick naju? online 1 present {naju zera}}]
$i eval {eggdrop_claim_nick 0 0 0 0 0}
check "claim: none free" naju [$i eval {set ::nick}]
set i [boot two_by_three "" {botnick naju? online 1 present {naju} joined 0}]
$i eval {eggdrop_claim_nick 0 0 0 0 0}
check "claim: waits until in every channel" naju [$i eval {set ::nick}]

# Jump gate: slot minute, 1800 s since the last move, a peer opped, off the
# slot server.
proc take {i minute} {
  $i eval [list eggdrop_take_server $minute 0 0 0 0]
  calls $i
}
set off {botnick zera serveraddress a.example.net:+6697 online 99000 peers {naju}}
set i [boot two_by_three "set eggdrop_boot_slot 1" $off]
check "jump: other minute" {} [take $i 2]
check "jump: slot minute with an opped peer" {{jump b.example.net +7000}} [take $i 3]
check "jump: gate holds for 1800 s" {{jump b.example.net +7000}} [take $i 5]
$i eval {incr ::now 1800}
check "jump: gate expires" {{jump b.example.net +7000} {jump b.example.net +7000}} [take $i 7]

set i [boot two_by_three "set eggdrop_boot_slot 1" {botnick zera serveraddress a.example.net:+6697 online 99000}]
check "jump: no opped peer, no jump" {} [take $i 3]
set i [boot two_by_three "set eggdrop_boot_slot 1" {botnick zera serveraddress b.example.net:+7000 online 99000 peers {naju}}]
check "jump: already on the slot server" {} [take $i 3]
set i [boot two_by_three "" {botnick naju? serveraddress a.example.net:+6697 online 99000 peers {zera}}]
check "jump: no listed name, no jump" {} [take $i 0]

# Server events come from the bot's own server log only. Channel text, private
# text and notices carry other levels or channels and must not forge one.
set i [boot two_by_three "" {online 1}]
$i eval {eggdrop_log_trying s * "Trying server a.example.net:+6697"}
check "genuine trying line sets the attempt" a.example.net:+6697 [$i eval {set eggdrop_attempt}]
set i [boot two_by_three "" {online 1}]
$i eval {eggdrop_log_trying p #c "<mallory> Trying server evil.example.net:+6697"}
$i eval {eggdrop_log_trying m * "\[mallory!x@y\] Trying server evil.example.net:+6697"}
$i eval {eggdrop_log_trying ms * "\[mallory!x@y to bot\] Trying server evil.example.net:+6697"}
$i eval {eggdrop_log_trying s * "-NOTICE- Trying server evil.example.net:+6697"}
check "forged trying lines change nothing" "" [$i eval {set eggdrop_attempt}]
check "forged trying lines log nothing" {} [calls $i]
foreach handler {eggdrop_log_failed eggdrop_log_dropped} {
  set i [boot two_by_three "" {online 0}]
  $i eval [list $handler p #c "<mallory> Failed connect to evil.example.net:+6697 (x) Disconnected from evil"]
  $i eval [list $handler m * "\[mallory!x@y\] Timeout: connect to evil"]
  check "forged line ($handler) logs nothing" {} [calls $i]
}
set i [boot two_by_three "" {online 0}]
$i eval {eggdrop_log_failed s * "Failed connect to a.example.net:+6697 (Connection refused)"}
check "genuine failed line logs" 1 [llength [calls $i]]
set i [boot two_by_three "" {online 0}]
$i eval {eggdrop_log_dropped s * "Disconnected from a.example.net:+6697"}
check "genuine disconnect line logs" 1 [llength [calls $i]]

# The launch hook is released once the bot is in every channel, when a
# channel's NAMES list ends as well as on the minute tick, and only once.
set i [boot two_by_three "" {botnick naju online 99900 joined 0}]
$i eval {eggdrop_release_on_names irc.example.net 366 "naju #c :End of /NAMES list."}
check "not in every channel and under 300 s: wait" {} [calls $i]
$i eval {incr ::now 300}
$i eval {eggdrop_release_launch 0 0 0 0 0}
check "300 s after connecting: release" {{exec /usr/local/bin/eggdrop-ready eggdrop launching}} [calls $i]
set i [boot two_by_three "" {botnick naju online 99900 joined 1}]
check "the names handler lets the built-in one run" 0 [$i eval {eggdrop_release_on_names irc.example.net 366 "naju #c :End of /NAMES list."}]
check "the bot in every channel releases at once" {{exec /usr/local/bin/eggdrop-ready eggdrop launching}} [calls $i]
$i eval {eggdrop_release_launch 0 0 0 0 0}
check "the hook is released once" 1 [llength [calls $i]]
set i [boot two_by_three "" {botnick naju online 0 joined 1}]
$i eval {eggdrop_release_on_names irc.example.net 366 "naju #c :End of /NAMES list."}
check "disconnected: nothing to release" {} [calls $i]

if {$failures > 0} {
  puts stderr "$failures failed"
  exit 1
}
puts ok
