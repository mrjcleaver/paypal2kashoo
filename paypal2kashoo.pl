#! /usr/bin/perl -w
use strict;
use warnings;
use Data::Dumper;

# Released under the GPL 3.0 http://www.gnu.org/copyleft/gpl.html
# You can find it on https://github.com/mrjcleaver/paypal2kashoo
# By Martin Cleaver http://martin.cleaver.org
# 2 Sep 2011

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
our $eol = "\r\n";
#print "skip ". $skip{'Temporary Hold'}."\n";

#die Dumper \%skip;

my $config_file = 'kashoopaypal.config';
require $config_file;

# Pass the name of the CSV file as a parameter to this script

my $input = $ARGV[0] || die "Pass name of CSV file containing Paypal transactions";

use POSIX qw(strftime);
my $today = strftime "%Y-%m-%d", localtime;

my $outputFile = $input.'output-$today.csv';
my $outFH = open ('>$outputFile', w) || die "Can't write to $outputFile - $!";

# SMELL - these parameters should be configurable.
my $start = 1; # 1, or a previous value of $limit - $count...
# ... if you need to start from somewhere other than the first row
my $limit = 1000; # how many records to input; a sample of 1 is a good test!
my $justPretend = 0;
# TODO - a log would be nice




use Tie::Handle::CSV;

# You might need to clean up the heading line to remove spaces.
my $fh = Tie::Handle::CSV->new($input, header => 1, key_case => 'any'); # Seems to need to be a Windows CSV file, without ^Ms

my $lineNumber = 1; # Because spreadsheets show to users first line as line 1
my $countDone = 0; 
my $totalHours = 0; 

my $rememberedToAmount = 0;
my $rememberedTxnID = 0;
my $rememberedToCurrency = '';
my $rememberedName = '';
my $prevName = ''; # So a currency entry can refer to the user's description of the transaction

output($fh->header);

print "Starting at line $start\n";
print "Stopping after $limit lines\n";
while (my $csv_line = <$fh>) {
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



    my $freshbooks_task_number = $task;
 
    if ($skip{$type}) {
	print "Skipping $date $name because it is of type $type\n";
	next;
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
		    $csv_line->{'name'} = $transfer_description; # overwriting the name
		    logTransfer($date,$type,$status,$currency,$transfer_description, $csv_line);
		} else {
		    die "\tERROR ".$csv_line->{'Reference Txn ID'}." ne $rememberedTxnID";
		}
	    }
    } else {
	logNormal($date, $type, $status, $currency, $name,
		  $csv_line, $countDone);
    }
    $prevName = $name;

    $countDone ++;
}

close $fh;
close $outFH;

sub logNormal {
    my ($date, $type, $status, $currency, $name, $csv_line, $countDone) = @_;

#    print "LOGGING NORMAL $countDone: date=$date\ntype=$type\nstatus=$status\nname=$name\n";
    output($csv_line)
}


sub logTransfer {
    my ($date, $type, $status, $currency, $name, $csv_line) = @_;

    print "LOGGING TRANSFER: date=$date\ntype=$type\nstatus=$status\nname=$name\n";
    output($csv_line);
}

sub output {
    my ($output) = @_;
    print $outFH $output.$eol;
}
