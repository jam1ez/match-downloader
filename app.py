#!/usr/bin/env python3
"""Match Downloader: single-user, loopback-only match video library. Starts the engine (jobs.py) and its HTTP API (server.py)."""
import argparse, signal, threading, webbrowser
from http.server import ThreadingHTTPServer
from jobs import DATA, LOCK, PROCESSES, idle_exit_watch, queue_loop, remove_token_file, terminate, write_token_file
from server import Handler

if __name__=='__main__':
    p=argparse.ArgumentParser(); p.add_argument('--port',type=int,default=8766); p.add_argument('--no-browser',action='store_true'); args=p.parse_args()
    server=ThreadingHTTPServer(('127.0.0.1',args.port),Handler)
    write_token_file()
    threading.Thread(target=queue_loop,daemon=True).start()
    threading.Thread(target=idle_exit_watch,args=(server,),daemon=True).start()
    url=f'http://127.0.0.1:{server.server_port}'
    print('Match Downloader running at '+url+'\nLibrary: '+str(DATA),flush=True)
    if not args.no_browser: webbrowser.open(url)
    def stop_server(*_):raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,stop_server)
    try: server.serve_forever()
    except KeyboardInterrupt:
        with LOCK:
            for proc in PROCESSES.values(): terminate(proc)
    finally: remove_token_file()
