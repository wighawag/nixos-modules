# modules/anon-dns.nix
#
# WHAT A BOX MUST DECLARE so that anonctl can actually confine an anon account's
# DNS. Sibling to modules/anon-accounts.nix, which declares the passwd slots and
# says in its own header that it declares users and nothing else; this module is
# the other half of "what anonctl needs from a declarative host", and it is
# box-wide networking rather than user declaration, so it lives on its own.
#
# It exists because a correctly jailed account on telemaque was measured leaking
# every hostname it looked up while `anonctl verify` reported all ten assertions
# green (anonctl's work/notes/findings/dns-confinement-defeated-by-nss-delegation-and-reply-un-nat.md,
# and its docs/adr/0011). Two independent defects, neither of which anonctl can
# fix from inside the account, because all three levers here are global host
# state owned by other modules.
#
# DEFECT 1: THE ACCOUNT'S NAMES ARE RESOLVED BY ANOTHER PROCESS.
# anonctl forces egress with `meta skuid <uid>`, which matches a socket's OWNER.
# glibc asks an nscd-compatible socket for the `hosts` database BEFORE it reads
# nsswitch.conf at all, and NixOS runs nsncd, so every `getaddrinfo` an anon
# account makes executes inside nsncd's process under uid `nscd`. No rule anonctl
# can write governs that socket. Measured: a name nothing could have cached
# resolved for the account while every counter on its own sockets stayed at zero.
#
# The fix is to make the daemon refuse the hosts database, which makes glibc fall
# back to resolving IN the calling process, on the account's own socket, where the
# forcing applies. That fallback is the load-bearing behaviour and it was measured
# rather than assumed (two nsncd instances, one default and one with the variable,
# each reached through a mount namespace whose resolv.conf pointed at a dead
# server: the default one RESOLVED a tailnet name, i.e. answered from the host's
# real resolver, and the ignoring one FAILED, i.e. glibc resolved in-process and
# hit the dead server).
#
# COST: nsncd exists so foreign-libc binaries (nix-ld, steam-run, FHS envs) can
# use this glibc's NSS plugins. With hosts ignored they resolve with their own
# libc instead, keeping `files` and `dns` but losing `mdns`/`mymachines`. Native
# programs are unaffected, and nsncd is non-caching, so no cache is lost. passwd
# and group are untouched, which is what NixOS actually needs nsncd for.
#
# DEFECT 2: THE SHIM'S ANSWER IS DESTROYED ON THE WAY BACK.
# The account's query IS redirected into anonctl's shim, and the shim DOES answer
# it over Tor. The answer then dies: conntrack un-NATs the reply's source back to
# the NAMESERVER's address before delivering it, and with MagicDNS as the system
# resolver that address (100.100.100.100) is inside 100.64.0.0/10, which
# tailscaled's own `ts-input` chain drops when it arrives on any interface other
# than tailscale0. Measured on the rule's own counters: the query was accepted (its
# source is this node's tailnet address, which has an explicit accept) and the
# answer was dropped, +89 bytes, across one probe.
#
# That rule is tailscaled's and is correct on its own terms, so the fix is to stop
# handing it a packet to judge: with a LOOPBACK system resolver the whole exchange
# stays on lo, where no source-address filter looks at it. This is general, not a
# Tailscale workaround: an off-box nameserver exposes the account's DNS answers to
# every ingress filter on the box, re-decided on every update of every such tool.
#
# THE TRAP IN THE OBVIOUS FIX, which is why the nssDatabases line below is forced:
# enabling systemd-resolved also makes nixpkgs add `resolve [!UNAVAIL=return]` to
# `system.nssDatabases.hosts` (nixos/modules/system/boot/resolved.nix, mkOrder
# 501). nss-resolve hands getaddrinfo to systemd-resolved over varlink, under uid
# `systemd-resolve`: the SAME out-of-process resolution nsncd was doing, just with
# a different daemon. Enabling resolved without removing that entry trades one
# bypass for the other and anonctl's `dns-nss-not-bypassed` stays red. We want the
# stub LISTENER without the NSS module.
{
  config,
  lib,
  ...
}: let
  cfg = config.nixos-modules.anonDns;

  # The hosts databases that resolve OUT OF PROCESS and can answer ARBITRARY
  # names, i.e. the ones that defeat per-UID forcing for everything the account
  # does. `mymachines` and `mdns*` also resolve out of process but only for a
  # bounded name class (machine names, `.local`), which anonctl reports as a
  # residual rather than refusing over; they are deliberately KEPT below, because
  # dropping mdns box-wide would break printer and scanner discovery for a leak
  # that cannot carry the account's ordinary traffic.
  broadDelegating = ["resolve" "sss" "winbind"];

  moduleName = entry: lib.head (lib.splitString " " entry);
in {
  options.nixos-modules.anonDns.enable = lib.mkEnableOption ''
    the host-side DNS configuration an anonctl anon account needs in order to be
    confined at all: an nscd-compatible daemon that does NOT answer the hosts
    database (so glibc resolves in the calling process, on the account's own
    socket, where `meta skuid` governs it), and a LOOPBACK system resolver (so the
    shim's answer is never un-NATed onto a source address some ingress filter
    drops). Neither is something anonctl can do from inside the account: both are
    global host state. See the header of this module for the measurements
  '';

  config = lib.mkIf cfg.enable {
    # HALF ONE: nsncd stops answering the hosts database, so glibc resolves
    # in-process. passwd/group/initgroups continue to be served, which is what
    # NixOS wants nsncd for.
    systemd.services.nscd.environment.NSNCD_IGNORE_HOSTS = "true";

    # HALF TWO: a loopback system resolver. tailscaled detects systemd-resolved
    # and installs MagicDNS as split DNS through it, so tailnet names keep working
    # for the rest of the box while /etc/resolv.conf becomes 127.0.0.53.
    services.resolved.enable = true;

    # ...WITHOUT nss-resolve. This is spelled as the EXACT list rather than a
    # filter because `system.nssDatabases.hosts` is assembled by several modules
    # through mkOrder/mkMerge and cannot be read back here without infinite
    # recursion. It reproduces this host's line as it stands today
    # (`mymachines mdns4_minimal [NOTFOUND=return] files myhostname dns mdns4`),
    # so the ONLY change is that resolved's entry never joins it.
    #
    # The cost of mkForce is that a future nixpkgs addition to this list would be
    # silently dropped here, which is exactly why the assertion below exists: it
    # fails the BUILD if a broad delegating module ever ends up in the final list,
    # rather than letting the box go quietly back to leaking.
    system.nssDatabases.hosts = lib.mkForce [
      "mymachines"
      "mdns4_minimal [NOTFOUND=return]"
      "files"
      "myhostname"
      "dns"
      "mdns4"
    ];

    assertions = [
      {
        assertion = !(lib.any (e: lib.elem (moduleName e) broadDelegating) config.system.nssDatabases.hosts);
        message = ''
          nixos-modules.anonDns: the nsswitch `hosts` line contains a module that resolves
          arbitrary names OUT OF PROCESS (${lib.concatStringsSep ", " broadDelegating}).
          A lookup such a daemon performs for an anon account runs under ITS uid, so
          anonctl's per-UID forcing cannot govern it and every name the account visits
          is resolved by this host's resolver. Remove the entry (see
          modules/anon-dns.nix), or turn nixos-modules.anonDns.enable off and accept that
          `anonctl verify` will report dns-nss-not-bypassed RED for every account.
        '';
      }
    ];
  };
}
