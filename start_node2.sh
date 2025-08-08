#!/bin/bash

echo "🚀 Starting Node2 (Publisher) with proper node name..."

# Compile the project first
gleam build

# Start Erlang node with proper name and run node2 module
ERL_FLAGS="-sname node2@localhost -setcookie my_cookie" gleam run -m node2
