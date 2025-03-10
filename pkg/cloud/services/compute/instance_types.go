/*
Copyright 2021 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

	http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package compute

import (
	"encoding/json"
	"fmt"
	"sort"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"

	infrav1 "sigs.k8s.io/cluster-api-provider-openstack/api/v1alpha6"
)

// InstanceSpec defines the fields which can be set on a new OpenStack instance.
//
// InstanceSpec does not contain all of the fields of infrav1.Instance, as not
// all of them can be set on a new instance.
type InstanceSpec struct {
	Name           string
	Image          string
	ImageUUID      string
	Flavor         string
	SSHKeyName     string
	UserData       string
	Metadata       map[string]string
	ConfigDrive    bool
	FailureDomain  string
	RootVolume     *infrav1.RootVolume
	Subnet         string
	ServerGroupID  string
	Trunk          bool
	Tags           []string
	SecurityGroups []infrav1.SecurityGroupParam
	Networks       []infrav1.NetworkParam
	Ports          []infrav1.PortOpts
}

// InstanceIdentifier describes an instance which has not necessarily been fetched.
type InstanceIdentifier struct {
	ID   string
	Name string
}

// InstanceStatus represents instance data which has been returned by OpenStack.
type InstanceStatus struct {
	server *ServerExt
	logger logr.Logger
}

func NewInstanceStatusFromServer(server *ServerExt, logger logr.Logger) *InstanceStatus {
	return &InstanceStatus{server, logger}
}

type networkInterface struct {
	Address string  `json:"addr"`
	Version float64 `json:"version"`
	Type    string  `json:"OS-EXT-IPS:type"`
}

// InstanceNetworkStatus represents the network status of an OpenStack instance
// as used by CAPO. Therefore it may use more context than just data which was
// returned by OpenStack.
type InstanceNetworkStatus struct {
	addresses map[string][]corev1.NodeAddress
}

func (is *InstanceStatus) ID() string {
	return is.server.ID
}

func (is *InstanceStatus) Name() string {
	return is.server.Name
}

func (is *InstanceStatus) State() infrav1.InstanceState {
	return infrav1.InstanceState(is.server.Status)
}

func (is *InstanceStatus) SSHKeyName() string {
	return is.server.KeyName
}

func (is *InstanceStatus) AvailabilityZone() string {
	return is.server.AvailabilityZone
}

// APIInstance returns an infrav1.Instance object for use by the API.
func (is *InstanceStatus) APIInstance(openStackCluster *infrav1.OpenStackCluster) (*infrav1.Instance, error) {
	i := infrav1.Instance{
		ID:         is.ID(),
		Name:       is.Name(),
		SSHKeyName: is.SSHKeyName(),
		State:      is.State(),
	}

	ns, err := is.NetworkStatus()
	if err != nil {
		return nil, err
	}

	clusterNetwork := openStackCluster.Status.Network.Name
	i.IP = ns.IP(clusterNetwork)
	i.FloatingIP = ns.FloatingIP(clusterNetwork)

	return &i, nil
}

// InstanceIdentifier returns an InstanceIdentifier object for an InstanceStatus.
func (is *InstanceStatus) InstanceIdentifier() *InstanceIdentifier {
	return &InstanceIdentifier{
		ID:   is.ID(),
		Name: is.Name(),
	}
}

// NetworkStatus returns an InstanceNetworkStatus object for an InstanceStatus.
func (is *InstanceStatus) NetworkStatus() (*InstanceNetworkStatus, error) {
	// Gophercloud doesn't give us a struct for server addresses: we get a
	// map of networkname -> interface{}. That interface{} is a list of
	// addresses as in the example output here:
	// https://docs.openstack.org/api-ref/compute/?expanded=show-server-details-detail#show-server-details
	//
	// Here we convert the interface{} into something more usable by
	// marshalling it to json, then unmarshalling it back into our own
	// struct.
	addressesByNetwork := make(map[string][]corev1.NodeAddress)
	for networkName, b := range is.server.Addresses {
		list, err := json.Marshal(b)
		if err != nil {
			return nil, fmt.Errorf("error marshalling addresses for instance %s: %w", is.ID(), err)
		}
		var interfaceList []networkInterface
		err = json.Unmarshal(list, &interfaceList)
		if err != nil {
			return nil, fmt.Errorf("error unmarshalling addresses for instance %s: %w", is.ID(), err)
		}

		var addresses []corev1.NodeAddress
		for i := range interfaceList {
			address := &interfaceList[i]

			// Only consider IPv4
			if address.Version != 4 {
				is.logger.V(6).Info("Ignoring IP address: only IPv4 is supported", "version", address.Version, "address", address.Address)
				continue
			}

			var addressType corev1.NodeAddressType
			switch address.Type {
			case "floating":
				addressType = corev1.NodeExternalIP
			case "fixed":
				addressType = corev1.NodeInternalIP
			default:
				is.logger.V(6).Info("Ignoring address with unknown type", "address", address.Address, "type", address.Type)
				continue
			}

			addresses = append(addresses, corev1.NodeAddress{
				Type:    addressType,
				Address: address.Address,
			})
		}

		addressesByNetwork[networkName] = addresses
	}

	return &InstanceNetworkStatus{addressesByNetwork}, nil
}

// Addresses returns a list of NodeAddresses containing all addresses which will
// be reported on the OpenStackMachine object.
func (ns *InstanceNetworkStatus) Addresses() []corev1.NodeAddress {
	// We want the returned order of addresses to be deterministic to make
	// it easy to detect changes and avoid unnecessary updates. Iteration
	// over maps is non-deterministic, so we explicitly iterate over the
	// address map in lexical order of network names. This order is
	// arbitrary.
	// Pull out addresses map keys (network names) and sort them lexically
	networks := make([]string, 0, len(ns.addresses))
	for network := range ns.addresses {
		networks = append(networks, network)
	}
	sort.Strings(networks)

	var addresses []corev1.NodeAddress
	for _, network := range networks {
		addressList := ns.addresses[network]
		addresses = append(addresses, addressList...)
	}

	return addresses
}

func (ns *InstanceNetworkStatus) firstAddressByNetworkAndType(networkName string, addressType corev1.NodeAddressType) string {
	if addressList, ok := ns.addresses[networkName]; ok {
		for i := range addressList {
			address := &addressList[i]
			if address.Type == addressType {
				return address.Address
			}
		}
	}
	return ""
}

// IP returns the first listed ip of an instance for the given network name.
func (ns *InstanceNetworkStatus) IP(networkName string) string {
	return ns.firstAddressByNetworkAndType(networkName, corev1.NodeInternalIP)
}

// FloatingIP returns the first listed floating ip of an instance for the given
// network name.
func (ns *InstanceNetworkStatus) FloatingIP(networkName string) string {
	return ns.firstAddressByNetworkAndType(networkName, corev1.NodeExternalIP)
}
