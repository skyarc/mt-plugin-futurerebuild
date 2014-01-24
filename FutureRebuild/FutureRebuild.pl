## SKYARC (C) 2004-2011 SKYARC System Co., Ltd., All Rights Reserved.
package MT::Plugin::SKR::FutureRebuild;

use strict;
use MT;
use MT::Plugin;
use base qw( MT::Plugin );
use MT::Entry;
use MT::PluginData;
use MT::WeblogPublisher;
use MT::Template::Context;
use MT::Util qw( days_in start_background_task );
#use Data::Dumper;#DEBUG

use vars qw( $MYNAME $VERSION );
$MYNAME = 'FutureRebuild';
$VERSION = '2.000';

my $plugin = __PACKAGE__->new({
        name => $MYNAME,
        id => lc $MYNAME,
        key => lc $MYNAME,
        version => $VERSION,
        author_name => '<__trans phrase="SKYARC System Co.,Ltd.">',
        author_link => 'http://www.skyarc.co.jp/',
        doc_link => 'http://www.skyarc.co.jp/engineerblog/entry/futurerebuild.html',
        description => <<HTMLHEREDOC,
<__trans phrase="Enable you the scheduled rebuilding of entries and webpages.">
HTMLHEREDOC
        l10n_class => 'MTCMSRebuilder::L10N',
        $MT::VERSION >= 6 ? ( system_config_template => \&_hdlr_system_config ) : (),
          
});
MT->add_plugin( $plugin );

sub instance { $plugin; }

### Registry
sub init_registry {
    my $plugin = shift;


    if ( $MT::VERSION >= 6 ) {

        $plugin->registry({
            applications => {
                cms => {
                    methods => {
                        'migration_future_unpublished'
                           => \&_hdlr_migration_future_unpublished,
                    },
                },
            },
        });
        return;
    }

    $plugin->registry({

        ## SmartphoneOption
        device_categories => {
            smartphone => {
                edit_entry_fields => {
                    future_unpublish => {
                        selector => '#future_unpublish-field',
                        display => 1,
                    },
                }, 
            },
        },

        callbacks => {
            'MT::App::CMS::template_source.edit_entry' => \&_edit_entry_source,
            'MT::App::CMS::template_param.edit_entry' => \&_edit_entry_param,
#            'MT::App::CMS::template_param.list_entry' => \&_list_entry_param,
            'cms_post_save.entry' => {
                priority => 9,
                code => \&_hdlr_post_save,
            },
            'cms_post_save.page' => {
                priority => 9,
                code => \&_hdlr_post_save,
            },
            'cms_save_filter.entry' => {
                priority => 1,
                code => \&_hdlr_save_filter,
            },
            'cms_save_filter.page' => {
                priority => 1,
                code => \&_hdlr_save_filter,
            },
            'MT::App::CMS::template_param.preview_strip' => \&_preview_strip_param,

            # for replaceable version's object swap
            'ReplaceableVersion::pre_swap' => \&_hdlr_replaceable_pre_swap,

            # start replaceable version
            'replaceable_version_post_save' => \&_hdlr_replaceable_version_post_save,

            # for DuplicateEntry:
            'duplicate_entry_post_save' => \&_hdlr_duplicate_entry_post_save,
        },
        tasks => {
            $MYNAME => {
                name        => $MYNAME,
                frequency   => 60,
                code        => \&_hdlr_future_unpublish,
            },
        },
        tags => {
            function => {
                UnpublishedDate => \&_tag_unpublished_date,
            },
            block => {
                'IfAfterUnpublishedDay?' => \&_tag_if_after_unpublished_day,
            },
        },
    });
}

sub _hdlr_system_config {
    my ($plugin, $param, $scope) = @_;

    return $plugin->translate_templatized(<<__HTMLHEREDOC__);
<mtapp:setting
   id="migration_future_unpublished"
   label="<__trans phrase="Upgrade">"
>
<a class="button" href="<mt:var name="script_url">?__mode=migration_future_unpublished"><__trans phrase="Transfer to MovableType6"></a>
<p class="hint">
<__trans phrase="This button is used to modify the function of &lt;Unpublished&gt; MovableType6 functions &lt;Future Unpublish&gt; of FutureRebuild plug-in.">
</p>
</mtapp:setting>
__HTMLHEREDOC__
 
}

sub _terms_for_future_unpublished {
   return {
      plugin => 'futurerebuild',
      key => { op => 'like' , value => 'entry_id::%' },
   };
}

sub _count_future_unpublished {
   my $terms = _terms_for_future_unpublished();
   require MT::PluginData;
   my $count = MT::PluginData->count($terms); 
}

sub _hdlr_migration_future_unpublished {
    my $app = shift;

    my $fr = MT->component('FutureRebuild')
       or die 'No FutureRebuild';

    my $count = _count_future_unpublished();

    ## 作業なし
    unless ( $count ) {
        return _finish_migration_future_unpublished( $app, $fr );
    }

    my $step = 100; ## 100件毎処理
    my $next = $count > $step ? 1 : 0;

    ## 実行
    my $terms = _terms_for_future_unpublished();
    require MT::PluginData;
    my $iter = MT::PluginData->load_iter($terms, { limit => $step });
    require MT::Entry;
    while ( my $data = $iter->() ) {

        my $msg = '';
        my $metadata = {};

        my $key = $data->key;
        my $entry = '';
        if ( $key =~ m{\Qentry_id::\E(\d+)} ) {
            my $entry_id = $1;
            if ( $entry_id ) {
                $entry = MT::Entry->load({ id => $entry_id }) || '';
            }
        }

        my $param = $data->data;
        $metadata->{key} = $key;
        $metadata->{mode} = $param->{mode};
        $metadata->{future_unpublish_date} = $param->{'time'};

        if ( $entry ) {

            $metadata->{entry_id} = $entry->id;
            $metadata->{entry_status} = $entry->status;
            $metadata->{entry_authored_on} = $entry->authored_on;
 
            if ( $param->{mode} && $param->{mode} == 1 && (( $entry->status || 0 ) != 6 ) ) {
                my $blog = $entry->blog;
                if ( $blog && !$entry->unpublished_on ) {
                   my $future_unpublish_ts = $metadata->{future_unpublish_date}; 
                   if ( $future_unpublish_ts =~ m{^\d{14}$} ) {

                       my $authored_ts = $entry->authored_on;
                       if ( $authored_ts >= $future_unpublish_ts ) {
                           $msg = $fr->translate('Migration failed.Published end date is too old from publication date.');
                       }
                       else { 
                          $msg = $fr->translate('Migration was successful.');
                          $entry->unpublished_on ( $future_unpublish_ts );
                          $entry->update or die $entry->errstr;
                       }
                   }
                }
            }
            else {
                $msg = $fr->translate('No migration.');
            }
        }
        else {
            $msg = $fr->translate('Migration failed. No Entry.');
        }

        if ( $msg ) {
            my $meta = '';
            for ( keys %$metadata ) {
                $meta .= sprintf ( "%s: %s\n" , $_ , $metadata->{$_} );
            }
            MT->log({
                message => 'FutureRebuild Migration: ' . $msg,
                $meta ? ( metadata => $meta ) : (),
                class => 'FutureRebuild',
            });
        }
        $data->remove;

    } 

    ## 残り作業
    if ( $next ) {
        return _next_migration_future_unpublished( $app, $fr, $count - $step );
    }
    ## 完了
    return _finish_migration_future_unpublished( $app, $fr );
}

sub _next_migration_future_unpublished {
    my ( $app, $class , $last) = @_;
    my $param = {};
    $param->{'next'} = 1;
    $param->{last_count} = $last > 0 ? $last : 0;
    return $class->load_tmpl('FutureRebuild/migration.tmpl', $param );
}

sub _finish_migration_future_unpublished {
    my ( $app, $class ) = @_;
    my $param = {};
    $param->{'next'} = 0;
    $param->{'finish'} = 1;
    return $class->load_tmpl('FutureRebuild/migration.tmpl', $param );
}

### Modify callback - template_source.edit_entry (V5)
sub _edit_entry_source {
    my ($eh_ref, $app_ref, $tmpl_ref) = @_;

    my $old = trimmed_quotemeta( <<'HTMLHEREDOC' );
    <mtapp:setting
        id="basename"
HTMLHEREDOC

    my $new = &instance->translate_templatized (<<'HTMLHEREDOC');
<mt:unless name="future_rebuild_disable">
<mt:setvarblock name="future_unpublish_label">
<input type="checkbox" id="future_unpublish_mode" name="future_unpublish_mode" <mt:if name="future_unpublish_mode" eq="1">checked="checked"</mt:if> value="1" onchange="on_change_future_unpublish(this);" style="margin-right: 4px" />
<__trans phrase="Set Scheduled Unpublish">
</mt:setvarblock>
<mtapp:setting
   id="future_unpublish"
   label="$future_unpublish_label"
   label_class="top-label"
   help_page="entries"
   help_section="date">
   <div id="future_unpublish_on">
     <div class="date-time-fields">
        <input type="text" id="UnpublishOn" class="text date<mt:if name="status_future"><mt:if name="can_publish_post"> highlight</mt:if></mt:if> text-date" name="unpublish_on_date" value="<$mt:var name="unpublish_on_date" escape="html"$>" />
        @ <input type="text" class="text time<mt:if name="status_future"><mt:if name="can_publish_post"> highlight</mt:if></mt:if>" name="unpublish_on_time" value="<$mt:var name="unpublish_on_time" escape="html"$>" />
     </div>
   </div>
</mtapp:setting>
<script type="text/javascript">
  function on_change_future_unpublish( obj ) {
     if (!obj)
       obj = DOM.getElement('future_unpublish_mode');
     var e = DOM.getElement('future_unpublish_on');
     var f = 0;
     if ( obj.checked ) 
         f = 1;

     e.style.display = ( f != '0' ? 'block' : 'none' );
  }
  on_change_future_unpublish( null );
</script>
</mt:unless>
HTMLHEREDOC

    $$tmpl_ref =~ s/($old)/$new$1/;
}

### Modify callback - template_param.edit_entry
sub _edit_entry_param {
    my ($cb, $app, $param, $tmpl) = @_;

    my ( $mode , $date , $time ) = ( 0 , '' , ''  );

    my $reedit = $app->param('reedit') || '';
    unless ( $reedit ) {
        if (my $entry_id = $param->{id} ) {
            if (my $settings = load_plugindata( key_name( $entry_id ))) {
                $mode = $settings->{mode} =~ m/^([0-1])$/ ? $1 : 0;

                if( my ( $dy , $dm , $dd , $th , $tm , $ts ) = 
                    $settings->{time} =~ m/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/ ){
                
                    $date = sprintf '%04d-%02d-%02d', $dy , $dm , $dd;
                    $time = sprintf '%02d:%02d:%02d', $th , $tm , $ts;
                }
            }
        }

        # Set default value
        $param->{future_unpublish_mode_change} = 0;
        $param->{future_unpublish_mode} = $mode;
        $param->{unpublish_on_date} = $date || $param->{authored_on_date};
        $param->{unpublish_on_time} = $time || $param->{authored_on_time};
    }

    # Returning from the preview screen.
    $param->{future_unpublish_mode} = $app->param('future_unpublish_mode') || 0
        if ( $app->param('_preview_file') || $reedit );

    $mode = $param->{future_unpublish_mode} =~ /(\d)/ ? $1 : 0;
    $param->{"future_unpublish_mode_$mode"} = 1;

    if ( $app->param('unpublish_on_date') ){
         if ( $reedit ) {
             $date = $app->param('unpublish_on_date');
         } else {
             $date = $app->param('unpublish_on_date') =~ m/^(\d{4}-\d{2}-\d{2})$/ ? $1 : '';
         }
         $param->{unpublish_on_date} = $date;
    }
    if( $app->param('unpublish_on_time') ){
         if ( $reedit ) {
             $time = $app->param('unpublish_on_time');
         } else {
             $time = $app->param('unpublish_on_time') =~ m/^(\d{2}:\d{2}:\d{2})$/ ? $1 : '';
         }
         $param->{unpublish_on_time} = $time; 
    }
    return 1;
}

### Modify callback - template_param.list_entry
sub _list_entry_param {
    my ($cb, $app, $param, $tmpl) = @_;

    $param->{object_loop}
        or return;

    my @object_loop = @{$param->{object_loop}};
    foreach (@object_loop) {
        my $pd = load_plugindata (key_name ($_->{id}));
        if ($pd->{time} && $pd->{mode} == 1) {
            my ($ts_y, $ts_m, $ts_d) = $pd->{time} =~ m/^(\d{4})(\d{2})(\d{2})/;
            $_->{created_on_relative} .= &instance->translate( '<br />- [_1]/[_2]/[_3]', $ts_y, $ts_m, $ts_d );
            $_->{created_on_formatted} .= &instance->translate( '<br />- [_1]/[_2]/[_3]', $ts_y, $ts_m, $ts_d );
        } else {
            $_->{created_on_relative} .= &instance->translate( '<br />(Stay Published)' );
            $_->{created_on_formatted} .= &instance->translate( '<br />(Stay Published)' );
        }
    }
    $param->{object_loop} = \@object_loop;
}

sub _load_data {
    my $entry_id = shift;

    my $mode =  0;
    my $date = '';
    my $time = '';

    my $pd = load_plugindata(key_name( $entry_id ));
    return ( $mode , $date , $time ) unless defined $pd && $pd;

    $mode = $pd->{mode} =~ m/^([0-1])$/ ? $1 : 0;
    if ( my ( $dy , $dm , $dd , $th , $tm , $ts ) =
            $pd->{time} =~ m/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/ ){

        $date = sprintf '%04d-%02d-%02d', $dy , $dm , $dd;
        $time = sprintf '%02d:%02d:%02d', $th , $tm , $ts;
    }
    return ($mode,$date,$time);
}

### Modify callback - template_param.preview_strip
sub _preview_strip_param {
    my ($cb, $app, $param, $tmpl) = @_;

    my $settings = {
        future_unpublish_mode => 0,
        unpublish_on_date     => $param->{'authored_on_date'},
        unpublish_on_time     => $param->{'authored_on_time'},
    };
    # load parameters if mode is approval_preview
    if ( $app->param( '__mode' ) eq 'approval_preview' ) {

        if ( $param->{id} ) {
            my ($mode,$date,$time) = _load_data( $param->{id} );
            $settings->{future_unpublish_mode} = $mode;
            $settings->{unpublish_on_date}     = $date;
            $settings->{unpublish_on_time}     = $time;

            $app->param( $_ , $settings->{$_} )
                for keys %$settings;
        }

    }
    for my $key ( keys %$settings ) {
        my $value = $app->param($key);
        $value = $settings->{$key} unless defined $value;
        push @{$param->{entry_loop}}, { data_name => $key, data_value => $value };
    }
    1;

}

### Update rebuild flag
sub _hdlr_post_save {
    my ($eh, $app, $obj) = @_;

    $obj->isa('MT::Entry') || $obj->isa('MT::Page')
        or return;

    my $q = MT->instance->{query}
        or return;

    ## 再入禁止
    return if MT->request->cache( 'future_rebuild_post_save');

    return if $q->param('__mode') eq 'regain_lock' ## for GetLock-plugin
           || ( $q->param('__mode') eq 'approve_workflow' && $q->param('sendback') ) ## for preview of sendback approval 
           || ( $q->param('__mode') eq 'view' && ( $q->param('_type') eq 'entry' || $q->param('_type') eq 'page' ) ); 

    my $mode = $q->param( 'future_unpublish_mode' ) || 0;
    $mode = $mode =~ m{^(0|1)$} ? $1 : 0;

    my $settings = load_plugindata( key_name( $obj->id || 0 ) );
    $settings ||= {};

    if ( $mode ) {

        my $date = $q->param( 'unpublish_on_date' ) || '';
        my $time = $q->param( 'unpublish_on_time' ) || '';

        my $ts = $date . ' ' . $time;
        $ts =~ m{^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$};
        $settings->{'time'} = sprintf '%04d%02d%02d%02d%02d%02d',
                $1, $2, $3, $4, $5, ( $6 || 0 );

	$settings->{'mode'} = $mode;
        $settings->{'rebuild'} = 1; # mark to rebuild
        save_plugindata( key_name( $obj->id ), $settings );

    } else {

        ### Reset.
        if ( exists $settings->{'mode'} ){
           remove_plugindata( key_name( $obj->id ));
        }

    }

    # 20732 delete param
    delete $q->{param}{future_unpublish_mode};
 
    ## 再入禁止
    MT->request->cache( 'future_rebuild_post_save' , 1 );
    return 1;
}


### Check unpublish_on
sub _hdlr_save_filter {
    my ( $cb, $app ) = @_;

    my $uo_d = $app->param( 'unpublish_on_date' );
    my $uo_t = $app->param( 'unpublish_on_time' );

    my $uo = $uo_d . ' ' . $uo_t;

    my %param = ();
    unless ( $uo
        =~ m!^(\d{4})-(\d{1,2})-(\d{1,2})\s+(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?$!
        )
    {
        $param{error} = $app->translate(
            "Invalid date '[_1]'; published on dates must be in the format YYYY-MM-DD HH:MM:SS.",
            $uo
        );
    }
    unless ( $param{error} ) {
        my $s = $6 || 0;
        $param{error}
            = $app->translate(
            "Invalid date '[_1]'; published on dates should be real dates.",
            $uo )
            if (
               $s > 59
            || $s < 0
            || $5 > 59
            || $5 < 0
            || $4 > 23
            || $4 < 0
            || $2 > 12
            || $2 < 1
            || $3 < 1
            || ( MT::Util::days_in( $2, $1 ) < $3
                && !MT::Util::leap_day( $0, $1, $2 ) )
            );
    }

    if ( defined $param{error} && $app->param( 'future_unpublish_mode' ) == 1 ) {
        $cb->error( $param{error} );
        return 0;
    } else {
        return 1;
    }
}


### Unpublish/Rebuild
sub _hdlr_future_unpublish {

    my @t = localtime;
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $t[5]+1900, $t[4]+1, @t[3,2,1,0];

    my %rebuild_blogs = ();

    my $iter = load_iter_plugindata();
    while (my $pd = $iter->() ){
        my $settings = $pd->data;
        my $id = $pd->key =~ /entry_id\:\:(\d*)/ ? $1 : 0; 
        next unless $id;

        my $entry = MT::Entry->load($id) or next;

        # Release -> Draft
        if ( $settings->{'mode'} && ($settings->{'mode'} == 1) && $entry->status == MT::Entry::RELEASE() ) {

	    next if !$settings->{'time'} || ($settings->{'time'} > $ts);

            ## Remove empty archives.
            my $app = MT->instance;
            my $old_entry = $entry->clone();

            ## 初期化
            $app->publisher->start_time(time);
            $app->request->reset;

            my $archive_delete = 0;
            if ( !MT->config('FutureRebuildNoDeleteArchiveFiles') && MT->config('DeleteFilesAtRebuild') ) { 

                ## FileInfoがないと削除できないので、このタイミング。
                my %recipe = $app->publisher->rebuild_deleted_entry(
                    Entry => $entry,
                    Blog  => $entry->blog
                );
                $archive_delete = 1;

            }

            $entry->status( MT::Entry::HOLD());
            $entry->modified_on( $ts );

            ## ステータスを下書きに戻す。この操作に合わせて、他のプラグインの為にコールバックを用意する
            if ( $app->run_callbacks( 'future_unpublish_pre_save.' . $entry->class , $entry , $old_entry , \%rebuild_blogs ) ) {
                $entry->update;
            }
            else {
                MT->log( $app->errstr );
            }
            $app->run_callbacks( 'future_unpublish_post_save.' . $entry->class , $entry , $old_entry , \%rebuild_blogs )
              or MT->log( $app->errstr );

            my $blog = MT::Blog->load( $entry->blog_id ) or next;
            $rebuild_blogs{$entry->blog_id} = 1;# mark to rebuild this blog
            my $archive_type = $entry->class_type eq 'entry' ? 'Individual' : 'Page';
            my ( $previous_old, $next_old ); 
            if ( $entry->authored_on ) {
                $previous_old = $entry->previous(1);
                $next_old     = $entry->next(1);
            }
 
            start_background_task(sub {

                if ( MT->config('DeleteFilesAtRebuild') ) {
                       $app->publisher->remove_entry_archive_file(
                          Entry => $entry,
                          ArchiveType => $archive_type,
                       );
                }

                ## 再構築 初期状態では動作しない。
                ## FutureRebuildNoDeleteArchiveFiles 1がmt-config.cgiに設定された場合、またはDeleteFilesAtRebuild 0が指定されたとき動作
                unless ( $archive_delete ) {

                    $app->run_callbacks('pre_build');
                    $app->rebuild_entry(
                        Entry             => $entry,
                        BuildDependencies => 1,
                        OldEntry          => $old_entry,
                        OldPrevious       => ($previous_old)
                        ? $previous_old->id
                        : undef,
                        OldNext => ($next_old) ? $next_old->id : undef
                    ) or MT->log($app->translate('FutureRebuild - UnPublished - Rebuild Error (entry_id:[_1] blog_id:[_1])' , $entry->id , $entry->blog_id ));
                    $app->run_callbacks('rebuild', $blog );
                    $app->run_callbacks('post_build');

                }

                ## MultiBlog Support
                if ( my $mb = MT->component('multiblog') ) {
                    my $action = MT->config('FutureRebuildMultiBlogUnpublishTrigger') || 'post_entry_save';
                    multiblog_runner( $mb, $action, undef, MT->instance, $entry );
                }

            });
            remove_plugindata( key_name( $entry->id ));
        }
        ## 定期的に空のレコードを削除
        elsif ( !$settings->{'mode'} ) {
            remove_plugindata( key_name( $entry->id ));
        }
    }

    ### Rebuild the all affected blogs.
    foreach my $blog_id (keys %rebuild_blogs) {
        next unless $blog_id;
        my $blog = MT::Blog->load($blog_id) or next;
       start_background_task(sub {
            MT->instance->publisher->start_time( time );
            MT->instance->request->reset;
            MT->instance->rebuild( Blog => $blog );
        });
    }

}

sub multiblog_runner {
    my $plugin = shift;
    my $method = shift;
    eval { require MultiBlog; };
    return if $@;

    MultiBlog::init_rebuilt_cache( MT->instance );

    multiblog_save_trigger( $plugin, @_ )
        if $method eq 'post_entry_save';

    multiblog_pub_trigger( $plugin, @_ )
        if $method eq 'post_entry_pub';
}

sub multiblog_save_trigger {
    my $plugin = shift;
    my ( $eh, $app, $entry ) = @_;
    my $blog_id = $entry->blog_id;
    my @scope = ( "blog:$blog_id", "system" );

    require MultiBlog;
    my $code = sub {
        my ($d) = @_;
        while ( my ( $id, $a ) = each( %{ $d->{'entry_save'} } ) ) {
            next if $id == $blog_id;
            MultiBlog::perform_mb_action( $app, $id, $_ ) foreach keys %$a;
        }

        require MT::Entry;
        if ( ( $entry->status || 0 ) != MT::Entry::RELEASE() ) {
            while ( my ( $id, $a ) = each( %{ $d->{'entry_pub'} } ) ) {
                next if $id == $blog_id;
                MultiBlog::perform_mb_action( $app, $id, $_ ) foreach keys %$a;
            }
        }
    };

    foreach my $scope (@scope) { 
        my $d = $plugin->get_config_value(
            $scope eq 'system' ? 'all_triggers' : 'other_triggers', $scope );
        $code->($d);
    }
    
    my $blog = $entry->blog;
    if ( my $website = $blog->website ) {
        my $scope = "blog:" . $website->id;
        my $d     = $plugin->get_config_value( 'blogs_in_website_triggers',
            $scope );
        $code->($d);
    }
}

sub multiblog_pub_trigger {
    my $plugin = shift;
    my ( $eh, $app, $entry ) = @_;
    my $blog_id = $entry->blog_id;

    require MultiBlog;
    my $code = sub {
        my ($d) = @_;

        require MT::Entry;
        if ( ( $entry->status || 0 ) != MT::Entry::RELEASE() ) {
            while ( my ( $id, $a ) = each( %{ $d->{'entry_pub'} } ) ) {
                next if $id == $blog_id;
                MultiBlog::perform_mb_action( $app, $id, $_ ) foreach keys %$a;
            }
        }
    };
    
    foreach my $scope ( "blog:$blog_id", "system" ) {
        my $d = $plugin->get_config_value(
            $scope eq 'system' ? 'all_triggers' : 'other_triggers', $scope );
        $code->($d);
    }

    my $blog = $entry->blog;
    if ( my $website = $blog->website ) { 
        my $scope = "blog:" . $website->id;
        my $d     = $plugin->get_config_value( 'blogs_in_website_triggers',
            $scope );
        $code->($d);
    }
}

### Template Tag - UnpublishedDate
sub _tag_unpublished_date {
    my ($ctx, $args) = @_;
    my $entry = $ctx->stash('entry')
        or return $ctx->_no_entry_error();
    my $settings = load_plugindata( key_name( $entry->id ))# entry_id
        or return '';
    $settings->{'mode'}
        or return '';
    $args->{ts} = $settings->{'time'};
    return MT::Template::Context::_hdlr_date ($ctx, $args);
}

### Conditional Tag - IfAfterUnpublishedDay
sub _tag_if_after_unpublished_day {
    my ($ctx, $arg, $cond) = @_;
    my $entry = $ctx->stash('entry')
        or return $ctx->_no_entry_error();
    my $settings = load_plugindata( key_name( $entry->id ))# entry_id
        or return 0;
    $settings->{'mode'}
        or return 0;
    my @t = localtime;
    my $ts = sprintf '%04d%02d%02d%02d%02d%02d', $t[5]+1900, $t[4]+1, @t[3,2,1,0];
    $settings->{'time'} <= $ts;
}

########################################################################
sub key_name { 'entry_id::'. $_[0]; }

sub save_plugindata {
    my ($key, $data_ref) = @_;
    my $pd = MT::PluginData->load({ plugin => &instance->id, key=> $key });
    if (!$pd) {
        $pd = MT::PluginData->new;
        $pd->plugin( &instance->id );
        $pd->key( $key );
    }
    $pd->data( $data_ref );
    $pd->save;
}

sub load_iter_plugindata {
   return MT::PluginData->load_iter( { plugin => &instance->id } ) || undef;
}

sub load_plugindata {
    my ($key) = @_;
    my $pd = MT::PluginData->load({ plugin => &instance->id, key=> $key })
        or return undef;
    $pd->data;
}

sub remove_plugindata {
    my ($key) = @_;
    my $pd = MT::PluginData->load({ plugin => &instance->id, key=> $key })
        or return undef;# there is no entry all along
    $pd->remove;
}

### Space and CR,LF trimmed quotemeta
sub trimmed_quotemeta {
    my ($str) = @_;
    $str = quotemeta $str;
    $str =~ s/(\\\s)+/\\s+/g;
    $str;
}

# handler for  swap event in ReplaceableVersion.
sub _hdlr_replaceable_pre_swap {
	my ($cb, $obj, $src) = @_;

    my $settings_src = load_plugindata( key_name( $src->id )) || {};
    my $settings_obj = load_plugindata( key_name( $obj->id )) || {};

#     use Data::Dumper;
#     MT->log('_hdlr_replaceable_pre_swap  ' . $src->id .  ' $settings_src : ' . Dumper($settings_src));
#     MT->log('_hdlr_replaceable_pre_swap ' . $obj->id .  ' $settings_obj : ' . Dumper($settings_obj));

    save_plugindata( key_name( $obj->id ), $settings_src);
    save_plugindata( key_name( $src->id ), $settings_obj);

    1;
}

# handler for create version event in ReplaceableVersion.
sub _hdlr_replaceable_version_post_save {
    my ($cg,$app,$new,$orig,$replaceable) = @_;

    my $settings_orig = load_plugindata( key_name( $orig->id )) || {};
    if ( exists $settings_orig->{mode} && $settings_orig->{mode} ) {
        save_plugindata( key_name( $new->id ), $settings_orig);
    }
    1;
}

# handler for entry duplication events.
sub _hdlr_duplicate_entry_post_save {
    my ($cb, $app, $mode, $entry, $original) = @_;
}

1;
