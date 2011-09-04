#! /usr/bin/perl -w
use strict;
use warnings;
use Data::Dumper;

# Released under the GPL 3.0 http://www.gnu.org/copyleft/gpl.html
# You can find it on https://github.com/mrjcleaver/paypal2kashoo
# By Martin Cleaver http://martin.cleaver.org
# 2 Sep 2011

# KNOWN BUG - Unsupported Binary Format when loading into Kashoo
# I usually load the csv into Excel and save as xls (2004) and try again. Sorry!

# This script takes an export file from PayPal and manipulates it so Kashoo, aided by the user, can do something intelligent with it
# It alters debits and credits from across currencies into something that the book-keeper can process as currency transfers
#
# It relies on you using the Bank Statement Importer
# You should try it on a new "Bank" account before using it on a real one
# You should ensure you understand how Kashoo acts with mutiple currency transactions in one account - it's a bit weird!
 
# This script is a horrid hack. 
# But it works. You are welcome to make it better.
# Do so on Github, please.

our %skip = ('Temporary Hold' => 1);
our $eol = "\n";
#print "skip ". $skip{'Temporary Hold'}."\n";

#die Dumper \%skip;

my $config_file = 'paypal2kashoo.config';
require $config_file;

# Pass the name of the CSV file as a parameter to this script

my $input = $ARGV[0] || die "Pass name of CSV file containing Paypal transactions";

use POSIX qw(strftime);
my $today = strftime "%Y-%m-%d", localtime;

my $outputFile = $input."-output-$today.csv";
my $feeFile = $input."-output-$today.fees";


# SMELL - these parameters should be configurable.
my $start = 1; # 1, or a previous value of $limit - $count...
# ... if you need to start from somewhere other than the first row
my $limit = 1000; # how many records to input; a sample of 1 is a good test!
my $justPretend = 0;
# TODO - a log would be nice

use Tie::Handle::CSV;

# You might need to clean up the heading line to remove spaces.
my $inputFH = Tie::Handle::CSV->new($input, header => 1, key_case => 'any'); # Seems to need to be a Windows CSV file, without ^Ms
open (my $outFH, ">", "$outputFile") || die "Can't write to $outputFile - $!";
open (my $feeFH, ">", "$feeFile") || die "Can't write to $feeFile - $!";

#Doesn't work
#my $outputFH = Tie::Handle::CSV->new($outputFile, open_mode => '>' )  ; #|| die "Can't write to $outputFile - $!";


my $lineNumber = 1; # Because spreadsheets show to users first line as line 1
my $countDone = 0; 
my $totalHours = 0; 

my $rememberedToAmount = 0;
my $rememberedTxnID = 0;
my $rememberedToCurrency = '';
my $rememberedName = '';
my $prevName = ''; # So a currency entry can refer to the user's description of the transaction

output($inputFH->header);

print "Starting at line $start\n";
print "Stopping after $limit lines\n";
while (my $csv_line = <$inputFH>) {
    $lineNumber++;

    print "\n";
    print "LINE: $lineNumber C: $countDone; $csv_line\n";
    if ($lineNumber <$start) {
	print " (skipping until line $start)\n";
	next;
    }
    if ($countDone >= $limit) {
	print "ABORTING AS COUNT ($countDone) >= LIMIT ($limit)\n";
	last;
    };
    my $date =$csv_line->{'Date'};
    $date =~ s/\(W.*\)//;

    if (! $csv_line->{'Date'}) {
	die "No Date column! Aborting!"; # The csv should always have the column, even if it is blank.
    } 

    if ($csv_line->{'Date'} eq 'XX') {
	print " (skipping line as not for us)\n";
	next;
    }

    my $type =  $csv_line->{'Type'};
    my $status = $csv_line->{'Status'};
    my $currency = $csv_line->{'Currency'};
    my $name = $csv_line->{'Name'};

    my $payment_type=  $csv_line->{'Payment Type'};
    $payment_type =~ s/\[/\(/;
    $payment_type =~ s/\]/\)/;
    $csv_line->{'Payment Type'} = $payment_type;

 
    if ($skip{$type}) {
	print "Skipping $date $name because it is of type $type\n";
	next;
    }


    my $fee = $csv_line->{'Fee'};
    if ($fee < 0) {
	my $currency = $csv_line->{'Currency'};
	my $gross = $csv_line->{'Gross'};
	my $net = $csv_line->{'Net'};
	my $feeDescription = "FEE of ".$fee." ".$currency." for ".$type." on ".$gross." (leaving ".$net." net) from ".$name." on ".$date;
#	print "\t".$feeDescription."\n";
	logFee($feeDescription, $csv_line, $countDone);
    }

    if ($type eq "Currency Conversion") {
	    if ($name =~ m/From/) {
		$rememberedToAmount = $csv_line->{'Net'};
		$rememberedTxnID = $csv_line->{'Reference Txn ID'};
		$rememberedToCurrency = $csv_line->{'Currency'};
		$rememberedName = $prevName;
		print "\tRemembered:$rememberedToAmount $rememberedToCurrency$rememberedTxnID\n";
	    } else {
		# A line after, hopefully!
		if ($csv_line->{'Reference Txn ID'} eq $rememberedTxnID) {
		    my $rememberedFromCurrency = $csv_line->{'Currency'};		
		    print "\tTRANSFER! Of ".$csv_line->{'Net'}.$rememberedFromCurrency." to ". $rememberedToAmount.$rememberedToCurrency."\n"; 
		    my $transfer_description ="$rememberedToAmount $rememberedToCurrency from $rememberedFromCurrency ($rememberedName/$rememberedTxnID) at ".$csv_line->{'Net'}.$rememberedFromCurrency." / ". $rememberedToAmount.$rememberedToCurrency;
		    print "\t".$transfer_description."\n";
		    logTransfer($transfer_description, $csv_line, $countDone);
		} else {
		    die "\tERROR ".$csv_line->{'Reference Txn ID'}." ne $rememberedTxnID";
		}
	    }
    } else {
	logNormal( $csv_line, $countDone);
    }
    $prevName = $name;

    $countDone ++;
}

close $inputFH;
close $outFH;
close $feeFH;

print "\nOutput is in $outputFile\n";
print "\nFees are in $feeFile - you have to account for these manually!\n";


sub lineAsString {
    my ($csv_line) = @_;
    return "date='".$csv_line->{'Date'}."'\ttype='".$csv_line->{'Type'}."'\tstatus='".$csv_line->{'Status'}."'\tname='".$csv_line->{'Name'}."'";
}

sub logNormal {
    my ($csv_line, $countDone) = @_;


    my $s = " - ";
    # overwriting the name
    $csv_line->{'name'} =
	$csv_line->{'Name'}.$s.
	$csv_line->{'Type'}.$s.
	$csv_line->{'Note'}.$s.
	$csv_line->{'To Email Address'}.$s.
	$csv_line->{'Transaction ID'}.$s.
	$csv_line->{'Payment Type'}.$s.
	$csv_line->{'Item Title'}.$s.
	$csv_line->{'Invoice Number'};

    print "LOGGING NORMAL $countDone:".lineAsString($csv_line)."\n";
    output($csv_line)
}


sub logTransfer {
    my ($transfer_description, $csv_line, $countDone) = @_;

    # overwriting the name
    $csv_line->{'name'} =
	$transfer_description;

    print "LOGGING TRANSFER $countDone:".lineAsString($csv_line)."\n";
    output($csv_line);
}


sub logFee {
    my ($fee_description, $csv_line, $countDone) = @_;

    # overwriting the name
    $csv_line->{'name'} =
	$fee_description;

#    print "LOGGING FEE $countDone:".lineAsString($csv_line)."\n";
#    print $feeFH ($csv_line);
    print $feeFH $fee_description."\n";
}



sub output {
    my ($output) = @_;
    print $outFH $output.$eol;
}
