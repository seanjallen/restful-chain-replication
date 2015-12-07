# restful-chain-replication

Fault-tolerant REST API implemented using chain replication.

## Purpose

This repo is mainly a silly experiment to try to implement chain replication using only http requests between standalone REST API servers. I noticed while writing it that there are not many decent simple example implementations of the algorithm online so this README file is an attempt help fill that gap.

The implementation is based on the algorithm as described in [this paper](http://www.cs.cornell.edu/home/rvr/papers/osdi04.pdf).

## Functionality

The servers have API endpoints that implement the standard query and update operations described in the paper. An update is replicated to all servers in the chain, and queries only return the state of the data that exists at all servers in the chain at the time of the query.

There are also endpoints that simulate a failure of the server, and a restart of a failed server that causes it to be added back into the chain.

There is also a simple (naive) master chain configuration service with an instance running at each server that expose some endpoints to stay in sync with each other.

## Endpoints

- GET: hostname:port/query/id
    - Returns the value of the object with the given id.
- POST: hostname:port/update/id/value 
    - Set the object with the given id to hold the given value.
- DELETE: hostname:port/server
    - Fails the server and removes it from the chain.
- PUT: hostname:port/server
    - Restarts the server and adds it back into the chain (as the new tail, see paper).
- GET: hostname:port/new-tail/new-server-port
    - Returns the state of all data stored at the tail of the chain so a newly added tail can download it and become the new tail of the chain.
- DELETE: hostname:port/sync/failed-port
    - Used by the master service to broadcast that a server has failed.
- PUT: hostname:port/sync/new-server-port
    - Used by the master service to broadcast that a server has been restarted and is the new tail of the chain.
    
## Requirements

In order to run this project you must have Node.js, npm, and Grunt installed. This code was developed and tested with grunt-cli v0.1.13, npm v2.7.3, and node v4.2.2.

## Running Instructions

After you clone the repository, you can build and run it by running these commands:

    npm install
  
    grunt compile
  
    grunt start:3000:3001:3002

grunt start:3000:3001:3002 causes three servers to startup on ports 3000, 3001, and 3002 using chain replication (3000 is the head, 3002 is the tail). You can then point your browser and your favorite REST API tester to http://localhost:port/query/id and the rest of the endpoints described above and test out how they work.

## Caveats

A few things to note to any distributed systems students who might have stumbled across this repo while working on a chain replication project for a class!

- Remember that the tail is supposed to send replies to all queries and updates. The tail sending replies to all queries is implemented in this project by all other servers using http redirects to forward queries sent to them to the tail. However the head does reply to update requests in this project after they are fully acked by every server after the head in the chain, including the tail (meaning they are replicated everywhere but the head tells the client that the update is complete in this project).
- The paper describes a separate chain configuration service running paxos that controls how the chain operates. This is a separate algorithm and implementing it is beyond the scope of this project. In it's place there is a simple (naive) master configuration service (in master.coffee) that simply broadcasts changes to the chain configuration to all nodes to keep the configuration in sync at all servers. This has many obvious issues and should not be looked at as an example.