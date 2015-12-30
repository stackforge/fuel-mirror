#!/usr/bin/python
# This script parses contents of given 'Source' files, and creates rsync
# command line to synchronize mirror

from __future__ import print_function
import re
import sys

# Regex to parse
regex = re.compile("^(?P<param>[a-zA-Z0-9_-]+):\s?(?P<value>.*)$")
files_regex = re.compile("(?P<md5>[a-f0-9]{32}) [0-9]+ (?P<filename>.*)")

for pkgfile in sys.argv[1:]:
    if pkgfile.endswith(".gz"):
        import gzip
        file = gzip.open(pkgfile)
    elif pkgfile.endswith(".bz2"):
        import bz2
        file = bz2.BZ2File(pkgfile)
    else:
        file = open(pkgfile)

    pkg = {}
    cur_param = ""

    for line in file:
        if line == "\n":
            #print("----------------------------------------------------")
            basedir = pkg['directory']
            files = files_regex.findall(pkg['files'])
            for md5, file in files:
                print(basedir + "/" + file)
            pkg = {}
            continue

        m = regex.match(line)
        if m:
            cur_param = m.group("param").lower()
            pkg[cur_param] = m.group("value")
        elif line.startswith(" "):
            # We got a multiliner continuation
            pkg[cur_param] += line.lstrip()
        else:
            print("IMMPOSSIBIRUUUU!!!!")
            sys.exit(999)
