# DNS Updater

This is a personal DNS updater written in Zig.

It is specifically for cloudflare, it will take in the API key and the DNS domain from the .env file to know what to check. It will check all 'A' records in that zone and make sure the IP address matched the current external IP address of the server this is run on.

The PATCH call has a dependence on c libcurl so it will need to be built to run.

`zig build run`