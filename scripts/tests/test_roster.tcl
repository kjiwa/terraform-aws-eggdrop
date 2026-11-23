# Runs the rendered eggdrop.tcl in a child interpreter with Eggdrop's commands
# stubbed, and checks the flag grants, the member sweep, channel settings, ban
# lifting and reset.
# Usage: tclsh test_roster.tcl DIR   (DIR holds roster.tcl)

set dir [lindex $argv 0]
set failures 0

proc check {name want got} {
  global failures
  if {$want ne $got} {
    puts stderr "FAIL: $name: expected '$want', got '$got'"
    incr failures
  }
}

proc boot {} {
  global dir
  set i [interp create]
  $i eval {
    set binds {}
    set chattrs {}
    set chancalls {}
    set killed {}
    set pushed {}
    set memberhandles {opnick bob voicenick carol voicednick carol oppednick bob strangernick *}
    set memberflags {bob {o a} carol {g v}}
    proc chanlist {channel} {
      if {$channel eq "#plain"} {return {opnick voicenick voicednick oppednick strangernick}}
      return {}
    }
    proc isop {nick channel} {expr {$nick eq "oppednick"}}
    proc isvoice {nick channel} {expr {$nick eq "voicednick"}}
    proc nick2hand {nick channel} {dict get $::memberhandles $nick}
    proc matchattr {handle flags channel} {
      if {![dict exists $::memberflags $handle]} {return 0}
      expr {[string index $flags 1] in [dict get $::memberflags $handle]}
    }
    proc pushmode {channel mode nick} {lappend ::pushed [list $channel $mode $nick]}
    set sent {}
    set reloads 0
    set bans {#guarded {{*!*@a.example setter 0 0 0} {*!*@b.example setter 0 0 0}} #plain {{*!*@c.example setter 0 0 0}}}
    proc bind {type flags mask proc} {lappend ::binds [list $type $flags $mask $proc]}
    proc binds {type} {return {}}
    proc unbind {args} {}
    proc userlist {args} {return {}}
    proc deluser {handle} {}
    proc adduser {args} {}
    proc setuser {args} {}
    proc chattr {handle flags channel} {lappend ::chattrs [list $handle $flags $channel]}
    set chansettings {#guarded {protectops 1 bitch 1 revenge 1} #plain {protectops 0 bitch 0 revenge 0}}
    proc channel {args} {
      if {[lindex $args 0] eq "get"} {
        return [dict get $::chansettings [lindex $args 1] [lindex $args 2]]
      }
      lappend ::chancalls $args
    }
    proc botonchan {channel} {return 1}
    proc botisop {channel} {return 1}
    proc channels {} {return {#guarded #plain}}
    proc utimer {args} {return t1}
    proc banlist {channel} {dict get $::bans $channel}
    proc killchanban {channel mask} {lappend ::killed [list $channel $mask]}
    proc reload {} {incr ::reloads}
    proc putserv {text} {lappend ::sent $text}
  }
  set fd [open [file join $dir roster.tcl]]
  set text [read $fd]
  close $fd
  $i eval $text
  return $i
}

proc handlers {i type mask} {
  set found {}
  foreach b [$i eval {set binds}] {
    lassign $b btype flags bmask proc
    if {$btype eq $type && $bmask eq $mask} {
      lappend found $proc
    }
  }
  return $found
}

set i [boot]
check "no channel setting is applied while the script is sourced" {} \
  [lsearch -all -inline -index 0 [$i eval {set chancalls}] set]
# A rehash re-reads the channel file after the script is sourced, so settings
# applied at source time are lost: only what the load handlers do counts.
$i eval {set chancalls {}}
foreach proc [handlers $i evnt userfile-loaded] {
  $i eval [list $proc userfile-loaded]
}

set grants [$i eval {set chattrs}]
check "peers are friends, masters and ops in every channel" \
  {{peers |+fmao #guarded} {peers |+fmao #plain}} \
  [lsearch -all -inline -index 0 $grants peers]
check "the owner is +fmao in a channel that lists it" 1 \
  [expr {[lsearch -exact $grants {alice |+fmao #guarded}] >= 0}]
check "the owner has nothing in a channel that omits it" {} \
  [lsearch -all -inline -index 2 [lsearch -all -inline -index 0 $grants alice] #plain]
check "a user is +ao, without friend or master" \
  {{bob |+ao #guarded} {bob |+ao #plain}} \
  [lsearch -all -inline -index 0 $grants bob]

check "a voice is +gv, without op" \
  {{carol |+gv #plain}} \
  [lsearch -all -inline -index 0 $grants carol]

$i eval eggdrop_grant_members
check "the sweep ops an unopped op, voices an unvoiced voice, and skips the rest" \
  {{{#plain} +o opnick} {{#plain} +v voicenick}} \
  [$i eval {set pushed}]
check "a userfile load schedules the sweep" 1 \
  [expr {[lsearch -exact [handlers $i evnt userfile-loaded] eggdrop_schedule_grant_members] >= 0}]

set chancalls [$i eval {set chancalls}]
check "a userfile load applies a toggled channel's settings" 1 \
  [expr {[lsearch -exact $chancalls {set #guarded +protectops +bitch +revenge revenge-mode 3 ban-time 120}] >= 0}]
check "a userfile load applies a default channel's settings" 1 \
  [expr {[lsearch -exact $chancalls {set #plain +protectops -bitch -revenge revenge-mode 3 ban-time 120}] >= 0}]

check "a snapshot lists the settings enabled on a channel" \
  {{"name":"","joined":true,"opped":true,"settings":["protectops","bitch","revenge"]}} \
  [$i eval {eggdrop_channel_json #guarded 0}]
check "a snapshot lists none for a channel with all disabled" \
  {{"name":"","joined":true,"opped":true,"settings":[]}} \
  [$i eval {eggdrop_channel_json #plain 0}]

check "every ban is lifted on a userfile load" \
  [lsort [list {{#guarded} *!*@a.example} {{#guarded} *!*@b.example} {{#plain} *!*@c.example}]] \
  [lsort [$i eval {set killed}]]

proc reset {i handle} {
  $i eval {set reloads 0; set sent {}}
  set proc [lindex [handlers $i msg reset] 0]
  $i eval [list $proc bot bot!x@y $handle ""]
  return [list [$i eval {set reloads}] [llength [$i eval {set sent}]]]
}

check "reset is bound" 1 [llength [handlers $i msg reset]]
check "reset from a stranger does nothing" {0 0} [reset $i *]
check "reset from another user does nothing" {0 0} [reset $i bob]
check "reset from the owner reloads and sends one notice" {1 1} [reset $i alice]
check "the notice goes to the sender" 1 \
  [string match "NOTICE bot :*" [lindex [$i eval {set sent}] 0]]

if {$failures > 0} {
  exit 1
}
puts "ok"
