#!/usr/bin/env python3
"""Loopback SSH server with separate password and keyboard-interactive users."""

import json
import socket
import threading

import paramiko


HOST_KEY = paramiko.RSAKey.generate(2048)


class Authentication(paramiko.ServerInterface):
    def __init__(self):
        self.round = 0

    def get_allowed_auths(self, username):
        return "keyboard-interactive" if username == "interactive" else "password"

    def check_auth_password(self, username, password):
        if username == "password" and password == "test password":
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_auth_interactive(self, username, submethods):
        if username != "interactive":
            return paramiko.AUTH_FAILED
        return paramiko.InteractiveQuery(
            "Server sign-in", "Enter the account and password.",
            ("Account", True), ("Password", False),
        )

    def check_auth_interactive_response(self, responses):
        if self.round == 0 and responses == ["test account", "test password"]:
            self.round = 1
            return paramiko.InteractiveQuery(
                "Verification", "Enter the code.", ("Code", False),
            )
        if self.round == 1 and responses == ["123456"]:
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED


def serve(connection):
    with paramiko.Transport(connection) as transport:
        transport.add_server_key(HOST_KEY)
        transport.start_server(server=Authentication())
        while transport.is_active():
            transport.accept(1)


with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    listener.listen()
    print(json.dumps({"port": listener.getsockname()[1]}), flush=True)
    while True:
        connection, _ = listener.accept()
        threading.Thread(target=serve, args=(connection,), daemon=True).start()
