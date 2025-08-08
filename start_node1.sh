#!/bin/bash

echo "🚀 Starting Node1 (Subscriber) with proper node name..."

# Compile the project first
gleam build

# Start Erlang node with proper name and run node1 module
ERL_FLAGS="-sname node1@localhost -setcookie my_cookie" gleam run -m node1
