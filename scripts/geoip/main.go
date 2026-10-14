// Trims the IPinfo Lite MMDB to an IPv4 country-only database and proves the extract against the full file.
//
//	geoip-trim <ipinfo_lite.mmdb> <geoip.mmdb> [ip ...]
package main

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"

	"github.com/maxmind/mmdbwriter"
	"github.com/maxmind/mmdbwriter/mmdbtype"
	"github.com/oschwald/maxminddb-golang"
)

type record struct {
	CountryCode string `maxminddb:"country_code"`
}

// A run of consecutive IPv4 addresses with one country; the writer stores it as the fewest aligned prefixes.
type span struct {
	first, last uint32
	country     string
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: geoip-trim <ipinfo_lite.mmdb> <geoip.mmdb> [ip ...]")
		os.Exit(2)
	}
	source, output, probes := os.Args[1], os.Args[2], os.Args[3:]

	full, err := maxminddb.Open(source)
	if err != nil {
		log.Fatalf("open %s: %v", source, err)
	}
	defer full.Close()

	spans := ipv4Spans(full)
	writeCountryDb(output, spans)

	trimmed, err := maxminddb.Open(output)
	if err != nil {
		log.Fatalf("reopen %s: %v", output, err)
	}
	defer trimmed.Close()

	info, _ := os.Stat(output)
	fmt.Printf("spans=%d bytes=%d build_epoch=%d\n", len(spans), info.Size(), trimmed.Metadata.BuildEpoch)
	if !probesAgree(full, trimmed, probes) {
		os.Exit(1)
	}
}

// Dropping the ASN fields makes neighbouring networks of one country identical, so they merge into one span.
func ipv4Spans(full *maxminddb.Reader) []span {
	// A 4-byte IP, or the reader walks the whole IPv6 tree; net.IPv4zero is the 16-byte form.
	all := &net.IPNet{IP: net.IP{0, 0, 0, 0}, Mask: net.CIDRMask(0, 32)}
	networks := full.NetworksWithin(all, maxminddb.SkipAliasedNetworks)
	var spans []span
	for networks.Next() {
		var rec record
		subnet, err := networks.Network(&rec)
		if err != nil {
			log.Fatalf("read network: %v", err)
		}
		if rec.CountryCode == "" {
			continue
		}
		first, last := bounds(subnet)
		if n := len(spans); n > 0 && spans[n-1].country == rec.CountryCode && spans[n-1].last+1 == first {
			spans[n-1].last = last
			continue
		}
		spans = append(spans, span{first: first, last: last, country: rec.CountryCode})
	}
	if err := networks.Err(); err != nil {
		log.Fatalf("iterate %s: %v", full.Metadata.DatabaseType, err)
	}
	return spans
}

func bounds(subnet *net.IPNet) (uint32, uint32) {
	first := binary.BigEndian.Uint32(subnet.IP.To4())
	ones, bits := subnet.Mask.Size()
	return first, first + (1<<(bits-ones) - 1)
}

func writeCountryDb(path string, spans []span) {
	writer, err := mmdbwriter.New(mmdbwriter.Options{
		DatabaseType:            "GnosisVPN-Country",
		Description:             map[string]string{"en": "Country-only IPv4 extract of IPinfo Lite (CC BY-SA 4.0), modified by Gnosis Ltd."},
		Languages:               []string{"en"},
		IPVersion:               4,
		RecordSize:              24,
		IncludeReservedNetworks: true,
	})
	if err != nil {
		log.Fatalf("writer: %v", err)
	}
	for _, s := range spans {
		data := mmdbtype.Map{"country_code": mmdbtype.String(s.country)}
		if err := writer.InsertRange(ipOf(s.first), ipOf(s.last), data); err != nil {
			log.Fatalf("insert %s-%s: %v", ipOf(s.first), ipOf(s.last), err)
		}
	}
	file, err := os.Create(path)
	if err != nil {
		log.Fatalf("create %s: %v", path, err)
	}
	defer file.Close()
	if _, err := writer.WriteTo(file); err != nil {
		log.Fatalf("write %s: %v", path, err)
	}
}

func ipOf(addr uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, addr)
	return ip
}

// Every probe must resolve to the same country in both files; a known exit going missing is a failed build.
func probesAgree(full, trimmed *maxminddb.Reader, probes []string) bool {
	agree := true
	for _, probe := range probes {
		ip := net.ParseIP(probe)
		if ip == nil {
			log.Fatalf("not an IP address: %s", probe)
		}
		want, got := countryOf(full, ip), countryOf(trimmed, ip)
		verdict := "ok"
		if want == "" || want != got {
			verdict, agree = "MISMATCH", false
		}
		fmt.Printf("%s\tfull=%s\ttrimmed=%s\t%s\n", probe, want, got, verdict)
	}
	return agree
}

func countryOf(reader *maxminddb.Reader, ip net.IP) string {
	var rec record
	if err := reader.Lookup(ip, &rec); err != nil {
		log.Fatalf("lookup %s: %v", ip, err)
	}
	return rec.CountryCode
}
