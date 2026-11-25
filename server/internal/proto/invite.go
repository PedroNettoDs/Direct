package proto

import "regexp"

var hostRE = regexp.MustCompile(`^[a-z0-9.-]{1,253}$`)

// ValidHost applies the QR hostname rule of docs/protocolo.md 4.2.
func ValidHost(h string) bool { return hostRE.MatchString(h) && h[len(h)-1] != '.' }

// InviteURI is the QR text of section 4.2.
func InviteURI(host string, inviteSeed, serverPub, escrowPub []byte) string {
	return "direct://enroll?v=1&h=" + host + "&t=" + B64Encode(inviteSeed) +
		"&s=" + B64Encode(serverPub) + "&e=" + B64Encode(escrowPub)
}
