// SPDX-License-Identifier: LGPL-3.0-or-later
// Minimal pipe-only media authentication adapter; no content decryption.
package main

import (
    "crypto/rand"
    "encoding/base64"
    "fmt"
    "io"
    "os"
    "strings"
    "github.com/objevovat/fairplay-sap-core-airplay2-sender-authentication-handshake/fpbridge"
)

func main() {
    if len(os.Args) == 2 && os.Args[1] == "m1" {
        fmt.Print(base64.StdEncoding.EncodeToString(fpbridge.NewFPSAPM1(fpbridge.FPSAPFullCapabilities)))
        return
    }
    if len(os.Args) != 2 || os.Args[1] != "m3" { os.Exit(2) }
    encoded, err := io.ReadAll(io.LimitReader(os.Stdin, 1025))
    if err != nil || len(encoded) > 1024 { os.Exit(3) }
    input, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
    if err != nil { os.Exit(4) }
    session, err := fpbridge.NewFPSAPSession(rand.Reader)
    if err != nil { os.Exit(5) }
    output, err := session.ExchangeM3(input)
    if err != nil { fmt.Fprintln(os.Stderr, "Invalid media authentication response"); os.Exit(6) }
    fmt.Print(base64.StdEncoding.EncodeToString(output))
}
