
---
layout: page
title: QUIC connection protocol
---

This document describes the wire specification of QUIC. The protocol
is modeled in terms of a sequence of *packet events* corresponding
to transmission of a UDP packet from a QUIC source endpoint to a
QUIC destination endpoint.

References
==========

```
include quic_types
include quic_frame
include quic_packet

```
Connections
===========

This section gives the wire specification of the QUIC protocol.  It
tracks the state of connections resulting from a sequence of packet
events.

History variables
-----------------

These history variables are referenced in the specification of QUIC
packet events.

- For each endpoint E, and cid C, `conn_seen(C,E)` is true if C has
  been sent by E.

- The predicate `initializing(C,S)` holds if client endpoint C has sent an
  Initial packet to server endpoint S, but the server has not replied.

- The packet number of the initial packet from client endpoint C to
  server endpoint S is represented by `initial_pkt_num(C,S)`.

- For each endpoint E and cid C, last_pkt_num(E,C) represents the
  number of the latest packet sent by E on C.

- For each endpoint E and cid C, sent_pkt(E,C,N) is true if
  a packet numbered N has been sent by E on C.

- For each endpoint E and cid C, acked_pkt(E,C,N) is true if
  a packet numbered N sent by E on connection C has been
  acknowledged. 

- For each endpoint E and cid C, max_acked(E,C) is the greatest
  packet number N such that acked_pkt(E,C,N), or zero if
  forall N. ~acked(E,C,N).

- For each endpoint E and cid C, ack_credit(E,C) is the number
  of non-ack-only packets sent to E on C, less the number of
  ack-only packets sent from E on C.


```
relation conn_seen(E:ip.endpoint,C:cid)
relation initializing(C:ip.endpoint,S:ip.endpoint)
function initial_pkt_num(C:ip.endpoint,S:ip.endpoint) : pkt_num
function last_pkt_num(E:ip.endpoint,C:cid) : pkt_num
relation sent_pkt(E:ip.endpoint,C:cid,N:pkt_num)
relation acked_pkt(E:ip.endpoint,C:cid,N:pkt_num)
function max_acked(E:ip.endpoint,C:cid) : pkt_num
function ack_credit(E:ip.endpoint,C:cid) : pkt_num

```
Initial state
-------------

The history variables are initialized as follows.  Initially, no
connections have been seen and no packets have been sent or
acknowledged.

```
after init {
    conn_seen(E,C) := false;
    sent_pkt(E,C,N) := false;
    acked_pkt(E,C,N) := false;
    max_acked(E,C) := 0;
    ack_credit(E,C) := 0;
}

```
Packet events
-------------

A packet event represents the transmision of a UDP packet `pkt` from
QUIC source endpoint `src` to a QUIC destination endpoint `dst`.

The packet *kind* depends on the field `hdr_type` according to
the following table:

  | hdr_type  | kind      |
  |-----------|-----------|
  | 0x7f      | Initial   |
  | 0x7d      | Handshake |


### Requirements

- An Initial packet represents an attempt by a client to establish a
  connection. The cid is arbitary, but must not have been previously
  seen. The initial packet must consist (apart from padding) of a
  single stream frame for stream zero, containing the initial security
  handshake information [1].

- A Handshake packet is sent in response to an Initial packet or
  a previous Handshake. In the latter case, the cid must match
  the original cid.

- TEMPORARY: We require that only one connection be initializing for
  a given client endpoint at a given time [2]. This seems unreasonable,
  but otherwise there is no way to match Handshake packets to Initial
  packets, at least without looking at the security information.

- A packet number may not be re-sent on a given connection. 

### Effects

- The `conn_seen` and `sent_pkt` relations are updated to reflect
  the observed packet [1].
- The `last_pkt_num` functiona is updated to indicate the observed
  packets as most recent for the packet's source and cid.
- For Initial packets, `initializing` is set to true for the packet's
  source and destination. The packet number is recorded in
  `initial_pkt_num` [3]. 
- For Handshake packets, `initializing` is set to false for the
  source and destination of the Initial packet (the reverse of the
  handshake packet). The initial packet is transfered to the cid
- A sender may not re-use a packet number on a given cid [4].
- A packet containing only ack frames and padding is *ack-only*.
  For a given cid, the number of ack-only packets sent from src to dst
  must not be greater than the number of non-ack-only packets sent
  from dst to src [5].
  

### Notes

- The effective packet number is computed according to the procedure
  `decode_packet_number` defined below.

- It isn't clear whether a packet that is multiply-delivered packet
  can be responded to by multple ack-only packets. Here, we assume it
  cannot. That is, only a new distinct packet number allows an ack-only
  packet to be sent in response.

```
before packet_event(src:ip.endpoint,dst:ip.endpoint,pkt:quic_packet) {

```
Extract the cid and packet number from the packet.

```
    var pcid := pkt.hdr_cid;
    var pnum := decode_packet_number(src,dst,pkt);

    require ~sent_pkt(src,pcid,pnum);  # [4]

```
Record that the connection has been seen from this source, and
the packet has been sent.

```
    conn_seen(src,pcid) := true;  # [1]
    sent_pkt(src,pcid,pnum) := true;  # [1]

```
Record the packet number as latest seen

```
    last_pkt_num(src,pcid) := pnum;

```
An ack-only packet must be in response to a non-ack-only packet

```
    var ack_only := forall (I:frame.idx) 0 <= I & I < pkt.payload.end ->
                                 (pkt.payload.value(I) isa frame.ack);
    if ack_only {
	require ack_credit(src,pcid) > 0;  # [5]
	ack_credit(src,pcid) := ack_credit(src,pcid) - 1;
    } else {
	ack_credit(dst,pcid) := ack_credit(dst,pcid) + 1;
    };

```
An Initial packet has hdr_type 0x7f

```
    if pkt.hdr_type = 0x7f {
        require pkt.payload.end = 1;  # [1]
	require pkt.payload.value(0) isa frame.stream;
        require ~initializing(src,dst);  # [2]

        initializing(src,dst) := true;  # [3]
        initial_pkt_num(src,dst) := pnum;  # [3]
    }

```
A Handshake packet has hdr_type 0x7d

```
    else if pkt.hdr_type = 0x7d {

```
Match the Handshake to the cid `icid` of an Initial packet sent
by the destination. We mark this connection as no longer
initializing and transfer the Initial packet to the new cid.

```
        if initializing(dst,src) {
            initializing(dst,src) := false;
            var ipnum := initial_pkt_num(dst,src);
            sent_pkt(dst,pcid,ipnum) := true;
            last_pkt_num(dst,pcid) := ipnum;
	    ack_credit(src,pcid) := 1;  # one credit for initial packet
        }
    };

```
Handle all of the frames

```
    var idx : frame.idx := 0;
    while idx < pkt.payload.end {
        call pkt.payload.value(idx).handle(src,dst,pcid);
        idx := idx + 1
    }

}


```
### Frame handlers

Extend `frame` with an action `handle` that handles a frame on the
wire.

```
object frame = {
   ...
   action handle(f:this,src:ip.endpoint,dst:ip.endpoint,pcid:cid) = {}
}

```
#### Ack handler

The set of packet numbers acknowledged by an Ack frame is determined
by the `largest_ack` field and the `ack_blocks` field. Each Ack
block acknowledges packet numbers in the inclusive range `[last - gap, last -
gap - blocks]` where `gap` and `blocks` are the fields of the Ack
block and `last` is `largest_ack` minus the sum of `gap + blocks`
for all the previous ack blocks.

Requirements:

- Every acknowledged packet must have been sent by the destination endpoint [1].

Effects:

- The acknowledged packets are recorded in the relation `acked_pkts(S,C,N)`
  where `S` is the *source* of the acknowledged packet (not of the Ack) `C` is
  the cid and `N` is the packet number [2].
- The greatest acked packet is also tracked in `max_act(S,C)` [3]

```
object frame = {
    ...
    object ack = {
        ...
        action handle(f:frame.ack,src:ip.endpoint,dst:ip.endpoint,pcid:cid) = {
            var idx : frame.ack.block.idx := 0;
            var last := f.largest_acked;
            if max_acked(dst,pcid) < last {
                max_acked(dst,pcid) := last;  # [3]
            };
            while idx < f.ack_blocks.end {
                var ack_block := f.ack_blocks.value(idx);
                var upper := last - ack_block.gap;
                last := upper - ack_block.blocks;
                require (last <= N & N <= upper) -> sent_pkt(dst,pcid,N);  # [1]
                acked_pkt(dst,pcid,N) := (last <= N & N <= upper) | acked_pkt(dst,pcid,N);  # [2]
                idx := idx.next;
            }
        }
    }
}


```
### Packet number decoding

The packet number is decoded from the packet header fields as follows.

If the connection is new, the field `hdr_pkt_num` gives the
exact first packet number. Otherwise, it represents only a number
of low order bits. The high-order bits must be inferred from the
last packet number seen for this connection.

For short format packets. the number of low order bits present
in `hdr_pkt_num` depends on the `hdr_type` field of the packet,
according to this table:

  | hdr_type | bits |
  |----------|------|
  | 0x1d     | 32   |
  | 0x1e     | 16   | 
  | 0x1f     |  8   |

For long format packets, the number of bits is always 32.  The
decoded packet number is the *least* number greater than the
last seen whose low-order bits agree with `hdr_pkt_num`.

Requirements

- The sent packet number must be no greater than `la + max/2` where
  `la` is the greatest acknowledged packet number (or zero if there
  have been no acks) and `max` is a largest number that can be
  represented with the number of bits provided [1].

Notes:

- The IETF draft uses this langauge: "The sender MUST use a packet
  number size able to represent more than twice as large a range
  than the difference between the largest acknowledged packet and
  packet number being sent." The meaning of "more than twice as
  large a range" isn't clear, but here we take it to mean that
  `2 * (pnum - la) ` is representable. It is also not clear how the
  maximum packet number is computed if no acks have been received,
  but we assume here that `la` is zero in this case.

  TODO: this seems inconsistent with the following statement: "The
  initial value for packet number MUST be selected randomly from a
  range between 0 and 2^32 - 1025 (inclusive)." Possibly there is no
  upper limit on the packet number if no acks have been received
  yet, but this seems questionable.

```
action decode_packet_number(src:ip.endpoint,dst:ip.endpoint,pkt:quic_packet) returns (pnum:pkt_num) = {

    var cid := pkt.hdr_cid;
    var la := max_acked(src,cid);
    pnum := pkt.hdr_pkt_num;


    if conn_seen(src,cid) {

```
This is a last number transmitted by the source on this connection.

```
        var last := last_pkt_num(src,cid);

```
If long format or type is 0x1d, we match 32 bits

```
        if pkt.hdr_long | pkt.hdr_type = 0x1d {
            require pnum <= la + 0x7ffffffe;
            if some(n:pkt_num) n > last & bfe[0][31](n) = pnum minimizing n {
                pnum := n
            }
        }

```
else if long format or type is 0x1e, we match 16 bits

```
        else if pkt.hdr_type = 0x1e {
            require pnum <= la + 0x7ffe;
            if some(n:pkt_num) n > last & bfe[0][15](n) = pnum minimizing n {
                pnum := n
            }
        }

```
else (type is 0x1f) we match 8 bits

```
        else {
            require pnum <= la + 0x7e;
            if some(n:pkt_num) n > last & bfe[0][7](n) = pnum minimizing n {
                pnum := n
            }
        }
    }
}