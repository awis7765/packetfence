package pfappserver::Model::Config::Networks;

=head1 NAME

pfappserver::Model::Config::Networks - Catalyst Model

=head1 DESCRIPTION

Configuration module for operations involving conf/networks.conf.

=cut

use Moose;  # automatically turns on strict and warnings
use namespace::autoclean;
use Net::Netmask;
use Readonly;

use pf::config;
use pf::config::ui;
use pf::error qw(is_error is_success);

extends 'pfappserver::Model::Config::IniStyleBackend';

Readonly::Scalar our $NAME => 'Networks';

sub _getName        { return $NAME };
sub _myConfigFile   { return $pf::config::network_config_file };


=head1 METHODS

=over

=item create

=cut
sub create {
    my ( $self, $network, $assignments ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $status_msg;

    # This method does not handle the network 'all'
    return ($STATUS::FORBIDDEN, "This method does not handle network $network") 
        if ( $network eq 'all' );

    my $networks_conf = $self->_load_conf();
    my $tied_conf = tied(%$networks_conf);

    if ( !$tied_conf->SectionExists($network) ) {
        $tied_conf->AddSection($network);
        while ( my ($param, $value) = each %$assignments ) {
            $tied_conf->newval( $network, $param, $value );
        }
        $self->_write_networks_conf();
    } else {
        $status_msg = "Network $network already exists";
        $logger->warn("$status_msg");
        return ($STATUS::PRECONDITION_FAILED, $status_msg);
    }

    $status_msg = "Network $network successfully created";
    $logger->info("$status_msg");
    return ($STATUS::OK, $status_msg);
}

=item delete

=cut
sub delete {
    my ( $self, $network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $status_msg;

    # This method does not handle the network 'all'
    return ($STATUS::FORBIDDEN, "This method does not handle network $network")  
        if ( $network eq 'all' );

    my $networks_conf = $self->_load_conf();
    my $tied_conf = tied(%$networks_conf);

    if ( $tied_conf->SectionExists($network) ) {
        $tied_conf->DeleteSection($network);
        $self->_write_networks_conf();
    } else {
        $status_msg = "Network $network does not exists";
        $logger->warn("$status_msg");
        return ($STATUS::NOT_FOUND, $status_msg);
    }

    $status_msg = "Network $network successfully deleted";
    $logger->info("$status_msg");
    return ($STATUS::OK, $status_msg);
}

=item getType

=cut
sub getType {
    my ( $self, $network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my ($status, $type) = ($STATUS::NOT_FOUND);
    # skip if we don't have a network address set
    if (defined($network)) {
        ($status, $type) = $self->read_value($network, 'type');
    }

    return ($status, $type);
}

=item getTypes

Returns an hashref with

    $interface => $type

For example

    eth0 => vlan-isolation

=cut
sub getTypes {
    my ( $self, $interfaces_ref ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $types_ref = {};
    foreach my $interface ( sort keys(%$interfaces_ref) ) {

        # skip if we don't have a network address set
        next if (!defined($interfaces_ref->{$interface}->{'network'}));

        my ($status, $type) = $self->read_value($interfaces_ref->{$interface}->{'network'}, 'type');
        if ( is_success($status) ) {
            $types_ref->{$interface} = $type;
        }
    }

    return ($STATUS::OK, $types_ref);
}

=item list_networks

Temporary method to return the list of currently configured networks in networks.conf since read_network returns
an array of array with the columns first...

=cut
sub list_networks {
    my ( $self ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    my @networks = ();
    foreach my $section ( keys %$networks_conf ) {
        push @networks, $section;
    }

    return ($STATUS::OK, \@networks);
}

=item getRoutedNetworks

Return the routed networks for the specified network and mask.

=cut

sub getRoutedNetworks {
    my ( $self, $network, $netmask ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    my @networks = ();
    foreach my $section ( keys %$networks_conf ) {
        next if ($section eq $network);
        my $next_hop = $networks_conf->{$section}->{next_hop};
        if ($next_hop && $self->getNetworkAddress($next_hop, $netmask) eq $network) {
            push @networks, $section;
        }
    }

    if (scalar @networks > 0) {
        @networks = sort @networks;
        return ($STATUS::OK, \@networks);
    }
    else {
        return ($STATUS::NOT_FOUND);
    }
}

=item read_value

=cut
sub read_value {
    my ( $self, $section, $param ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $status_msg;

    my $networks_conf = $self->_load_conf();

    # Warning: autovivification causes interfaces to be created if the section
    # is not looked on her own first when the file is written later.
    if (!defined($networks_conf->{$section}) || !defined($networks_conf->{$section}->{$param})) {
        $status_msg = "$section.$param does not exists";
        $logger->warn("$status_msg");
        return ($STATUS::NOT_FOUND, $status_msg);
    }

    $status_msg = $networks_conf->{$section}->{$param} || '';

    return ($STATUS::OK, $status_msg);    
}

=item read_network

Return a table representation of a network defined in networks.conf
according to the field order defined in ui.conf

=cut
sub read_network {
    my ( $self, $network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    my @columns = pf::config::ui->instance->field_order('networkconfig get'); 
    my @resultset = [@columns];

    foreach my $section ( keys %$networks_conf ) {
        if ( ($network eq 'all') || ($network eq $section) ) {
            my @values;
            foreach my $column (@columns) {
                push @values, ( $networks_conf->{$section}->{$column} || '' );
            }
            push @resultset, [@values];
        }
    }

    if ( $#resultset > 0 ) {
        return ($STATUS::OK, \@resultset);
    }
    else {
        return ($STATUS::NOT_FOUND, "Unknown network $network");
    }
}

=item read

Return the hash representation of a network defined in networks.conf

=cut
sub read {
    my ( $self, $network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    my @resultset = ();

    foreach my $section ( keys %$networks_conf ) {
        if ( ($network eq 'all') || ($network eq $section) ) {
            push @resultset, $networks_conf->{$section};
        }
    }

    if ( scalar @resultset > 0 ) {
        return ($STATUS::OK, \@resultset);
    }
    else {
        return ($STATUS::NOT_FOUND, "Unknown network $network");
    }
}

=item update

=cut
sub update {
    my ( $self, $network, $assignments ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $status_msg;

    # This method does not handle the network 'all'
    return ($STATUS::FORBIDDEN, "This method does not handle network $network")
        if ( $network eq 'all' );

    my $networks_conf = $self->_load_conf();
    my $tied_conf = tied(%$networks_conf);

    if ( $tied_conf->SectionExists($network) ) {
        while ( my ($param, $value) = each %$assignments ) {
            if ( defined( $networks_conf->{$network}->{$param} ) ) {
                $tied_conf->setval( $network, $param, $value );
            } else {
                $tied_conf->newval( $network, $param, $value );
            }
        }
        $self->_write_networks_conf();
    } else {
        $status_msg = "Network $network does not exists";
        $logger->warn("$status_msg");
        return ($STATUS::NOT_FOUND, $status_msg);
    }

    $status_msg = "Network $network successfully modified";
    $logger->info("$status_msg");
    return ($STATUS::OK, $status_msg);
}

=item update_network

=cut
sub update_network {
    my ( $self, $network, $new_network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $status_msg;

    # This method does not handle the network 'all'
    return ($STATUS::FORBIDDEN, "This method does not handle network $network")
        if ( $network eq 'all' );

    my $networks_conf = $self->_load_conf();
    my $tied_conf = tied(%$networks_conf);
    if (exists $networks_conf->{$network}) {
        my $network_ref = $networks_conf->{$network};
        $networks_conf->{$new_network} = $network_ref;
        delete $networks_conf->{$network};
        $self->_write_networks_conf();
    }
    else {
        $logger->error("Network $network not found");
    }

    $status_msg = "Network $network successfully renamed to $new_network";
    $logger->info("$status_msg");
    return ($STATUS::OK, $status_msg);
}

=item exist

=cut
sub exist {
    my ( $self, $network ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    my $tied_conf = tied(%$networks_conf);

    return $TRUE if ( $tied_conf->SectionExists($network) );
    return $FALSE;
}


=item getNetworkAddress

Calculate the network address for the provided ipaddress/network combination

Returns undef on undef IP / Mask

=cut
sub getNetworkAddress {
    my ( $self, $ipaddress, $netmask ) = @_;

    return if ( !defined($ipaddress) || !defined($netmask) );
    return Net::Netmask->new($ipaddress, $netmask)->base();
}

=head1 METHODS TO GET RID OF

=over


=item _write_networks_conf

=cut
# TODO: Meant to be removed... (dwuelfrath@inverse.ca 2012.12.20)
sub _write_networks_conf {
    my ( $self ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $networks_conf = $self->_load_conf();
    tied(%$networks_conf)->WriteConfig($network_config_file)
        or $logger->logdie(
            "Unable to write configs to $network_config_file. You might want to check the file's permissions."
        );
    $logger->info("Successfully write configs to $network_config_file");
}


=back

=head1 COPYRIGHT

Copyright (C) 2012-2013 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

__PACKAGE__->meta->make_immutable;

1;
