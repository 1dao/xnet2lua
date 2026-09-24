package.path = 'scripts/?.lua;' .. package.path
local spec = dofile('tests/lua/spec_helper.lua')
local json = require('xutils')
local codec = require('xagent.llm.responses')
local function event(decoder, kind, value)
    value = value or {}; value.type = kind
    decoder:on_sse(kind, json.json_pack(value))
end
spec.describe('Responses codec', function()
    spec.it('builds Codex requests without API-only output limits', function()
        local req = codec.build_request({auth_type='chatgpt', model='test', api_key='test-token', account_id='account'},
            {messages={{role='user',content='hi'}},system='instructions', max_tokens=50,
             tools={{name='Read',input_schema={type='object',properties={}}}}})
        local body = json.json_unpack(req.body)
        spec.equal(req.url, 'https://chatgpt.com/backend-api/codex/responses')
        spec.equal(req.headers['ChatGPT-Account-Id'], 'account')
        spec.equal(body.instructions,'instructions'); spec.equal(body.store,false)
        spec.nil_value(body.max_output_tokens); spec.equal(body.tools[1].name,'Read')
        spec.equal(body.tools[1].strict,false)
    end)
    spec.it('supports API key Responses independently', function()
        local r = codec.build_request({base_url='https://api.example/v1',model='test',api_key='key'},
            {messages={{role='user',content='hi'}}, max_tokens=50})
        spec.equal(r.url,'https://api.example/v1/responses')
        spec.equal(json.json_unpack(r.body).max_output_tokens,50)
    end)
    spec.it('preserves reasoning and pairs tool outputs by call_id', function()
        local reasoning={type='reasoning',id='rs_1',encrypted_content='opaque',summary={}}
        local out=codec.convert_messages({
            {role='assistant',content={{type='thinking',thinking='',responses_item=reasoning},
                {type='tool_use',id='call_1',name='Read',input={path='a'}}}},
            {role='user',content={{type='tool_result',tool_use_id='call_1',content='file text'}}},
        })
        spec.equal(out[1].encrypted_content,'opaque')
        spec.equal(out[2].call_id,'call_1'); spec.equal(out[3].call_id,'call_1')
        spec.equal(out[3].type,'function_call_output'); spec.equal(out[3].output,'file text')
    end)
    spec.it('converts images and tool result images', function()
        local img={type='image',source={type='base64',media_type='image/jpeg',data='YWJj'}}
        local out=codec.convert_messages({{role='user',content={img,
            {type='tool_result',tool_use_id='c',content={{type='text',text='image'},img}}}}})
        spec.equal(out[1].content[1].image_url,'data:image/jpeg;base64,YWJj')
        spec.equal(out[2].output,'image'); spec.equal(out[3].content[1].type,'input_image')
    end)
    spec.it('encodes empty reasoning summaries as arrays without changing history', function()
        local reasoning = {type='reasoning',id='rs',summary={},encrypted_content='opaque'}
        local r=codec.build_request({auth_type='chatgpt',model='test'},
            {messages={{role='assistant',content={{type='thinking',responses_item=reasoning}}}}})
        spec.contains(r.body,'"summary":[]')
        spec.truthy(type(reasoning.summary)=='table')
        r=codec.build_request({model='test'},{messages={}})
        spec.contains(r.body,'"input":[]')
    end)
    spec.it('assembles parallel function calls and avoids duplicate text', function()
        local text, result, starts='',nil,0
        local d=codec.new_decoder({on_text=function(v) text=text..v end,
            on_tool_use_start=function() starts=starts+1 end,on_done=function(v) result=v end})
        event(d,'response.output_item.added',{output_index=0,item={type='message',content={}}})
        event(d,'response.output_text.delta',{output_index=0,content_index=0,delta='Hello'})
        event(d,'response.output_item.added',{output_index=1,item={type='function_call',call_id='a',name='Read'}})
        event(d,'response.output_item.added',{output_index=2,item={type='function_call',call_id='b',name='Read'}})
        event(d,'response.function_call_arguments.delta',{output_index=1,delta='{"path":'})
        event(d,'response.function_call_arguments.delta',{output_index=2,delta='{"path":"b"}'})
        event(d,'response.function_call_arguments.delta',{output_index=1,delta='"a"}'})
        event(d,'response.completed',{response={id='r',usage={input_tokens=10,output_tokens=3,input_tokens_details={cached_tokens=4}},
            output={{type='message',content={{type='output_text',text='Hello'}}},
                {type='function_call',call_id='a',name='Read',arguments='{"path":"a"}'},
                {type='function_call',call_id='b',name='Read',arguments='{"path":"b"}'}}}})
        d:finish()
        spec.equal(text,'Hello');spec.equal(starts,2);spec.equal(result.stop_reason,'tool_use')
        spec.equal(result.message.content[2].input.path,'a');spec.equal(result.message.content[3].input.path,'b')
        spec.equal(result.usage.input_tokens,6);spec.equal(result.usage.cache_read_input_tokens,4)
    end)
    spec.it('rejects truncated streams even after receiving tool arguments', function()
        local result,err
        local d=codec.new_decoder({on_done=function(v) result=v end,on_error=function(v) err=v end})
        event(d,'response.output_item.added',{output_index=0,item={type='function_call',call_id='a',name='Read'}})
        event(d,'response.function_call_arguments.delta',{output_index=0,delta='{"path":"x"}'})
        d:finish();spec.nil_value(result);spec.contains(err,'before completion')
    end)
    spec.it('reports incomplete responses and API errors', function()
        local result,err
        local d=codec.new_decoder({on_done=function(v) result=v end})
        event(d,'response.incomplete',{response={incomplete_details={reason='max_output_tokens'},output={}}})
        spec.equal(result.stop_reason,'max_tokens')
        d=codec.new_decoder({on_error=function(v) err=v end})
        event(d,'response.failed',{response={error={message='quota reached'}}})
        spec.equal(err,'quota reached')
    end)
    spec.it('does not send Responses reasoning metadata to Anthropic', function()
        local a=require('xagent.llm.anthropic')
        local messages={{role='assistant',content={{type='thinking',thinking='',responses_item={type='reasoning'}},
            {type='text',text='hello'}}}}
        local wire=a._wire_messages(messages)
        spec.equal(#wire[1].content,1);spec.equal(#messages[1].content,2)
    end)
end)
local failures=spec.finish()
return {__init=function() if failures>0 then os.exit(1) end; xthread.stop(0) end}
