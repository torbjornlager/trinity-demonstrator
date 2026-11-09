%% Linda: programs belonging to different users share a blackboard.
%
% Select n3, n4, n5, or the owner-only N7 shell. The node supplies these
% predicates; this file contains only examples of using them.
%
% Try with a partner or two browser sessions on the SAME node. Agree on a
% group name (my_group below). Tuples stay in the service after a client leaves.
% Group names are conventions for avoiding collisions, not access controls.
%
% linda_out(T) adds a ground tuple.
% linda_in(T)  takes a matching tuple, waiting if necessary.
% linda_rd(T)  reads a matching tuple without taking it, waiting if necessary.
% linda_inp(T) and linda_rdp(T) fail immediately when there is no match.

/** <examples>

% Producer (Alice): put something on the blackboard, then leave if you like.
?- linda_out(message(my_group, hello)).

% Consumer (Bob, another session): take Alice's message. May be run first.
?- linda_in(message(my_group, Message)).

% Synchronization: Bob waits here until Alice publishes the ready signal.
?- linda_in(ready(my_group)).

% Alice releases Bob by publishing the signal in her own session.
?- linda_out(ready(my_group)).

% Shared data: Alice publishes a setting.
?- linda_out(setting(my_group, colour, green)).

% Any client can read it; reading leaves the tuple available to other clients.
?- linda_rd(setting(my_group, colour, Colour)).

% A nonblocking read lets the program handle missing data immediately.
?- (  linda_rdp(setting(my_group, size, Size))
   -> write(Size),
      nl
   ;  write('No size has been published'),
      nl
   ).

% Clean up the shared setting by taking it.
?- linda_inp(setting(my_group, colour, green)).

*/
