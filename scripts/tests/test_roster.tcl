# Runs the rendered eggdrop.tcl in a child interpreter with Eggdrop's commands
# stubbed, and checks the flag grants, channel settings, ban lifting and reset.
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
    proc channel {args} {lappend ::chancalls $args}
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

set chancalls [$i eval {set chancalls}]
check "a toggled channel is protected and punishes" 1 \
  [expr {[lsearch -exact $chancalls {set #guarded +protectops +bitch +revenge revenge-mode 3 ban-time 120}] >= 0}]
check "a default channel is neither" 1 \
  [expr {[lsearch -exact $chancalls {set #plain +protectops -bitch -revenge revenge-mode 3 ban-time 120}] >= 0}]

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
